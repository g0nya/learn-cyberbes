"""Native Windows adapter traffic monitor, without packet capture."""
from __future__ import annotations

import argparse
import csv
import ctypes
from dataclasses import dataclass
from datetime import datetime
import math
from pathlib import Path
import shutil
import sys
import time


CSV_FIELDS = ("Timestamp", "AdapterName", "ReceivedBytesPerSecond", "SentBytesPerSecond",
              "SessionReceivedBytes", "SessionSentBytes", "ReceivedDeltaBytes",
              "SentDeltaBytes", "CounterReset")


@dataclass(frozen=True)
class Counters:
    received: int
    sent: int


@dataclass
class History:
    baseline: Counters | None = None
    elapsed: float = 0.0
    received_total: int = 0
    sent_total: int = 0


@dataclass(frozen=True)
class Measurement:
    timestamp: str
    adapter: str
    received_rate: float
    sent_rate: float
    received_total: int
    sent_total: int
    received_delta: int
    sent_delta: int
    reset: bool

    def csv_record(self) -> dict:
        return dict(zip(CSV_FIELDS, (self.timestamp, self.adapter, self.received_rate,
                    self.sent_rate, self.received_total, self.sent_total,
                    self.received_delta, self.sent_delta, self.reset)))


class TrafficState:
    def __init__(self) -> None:
        self.adapters: dict[str, History] = {}

    def update(self, counters: dict[str, Counters], elapsed: float) -> list[Measurement]:
        for name, history in self.adapters.items():
            if name not in counters:
                history.baseline = None
        rows = []
        timestamp = datetime.now().astimezone().isoformat()
        for name, current in sorted(counters.items()):
            if current.received < 0 or current.sent < 0:
                raise ValueError(f"Отрицательный счётчик адаптера: {name}")
            history = self.adapters.setdefault(name, History())
            received_delta = sent_delta = 0
            received_rate = sent_rate = 0.0
            reset = False
            if history.baseline is not None:
                interval = elapsed - history.elapsed
                if interval <= 0:
                    raise ValueError("Время между измерениями должно увеличиваться.")
                reset = (current.received < history.baseline.received or
                         current.sent < history.baseline.sent)
                received_delta = max(0, current.received - history.baseline.received)
                sent_delta = max(0, current.sent - history.baseline.sent)
                received_rate, sent_rate = received_delta / interval, sent_delta / interval
            history.received_total += received_delta
            history.sent_total += sent_delta
            history.baseline, history.elapsed = current, elapsed
            rows.append(Measurement(timestamp, name, received_rate, sent_rate,
                        history.received_total, history.sent_total,
                        received_delta, sent_delta, reset))
        return rows


class WindowsAdapters:
    def __init__(self) -> None:
        if sys.platform != "win32":
            raise RuntimeError("Программа предназначена для Windows 11.")
        try:
            import psutil
        except ImportError as exc:
            raise RuntimeError("Не установлен psutil. Выполните тем же Python: "
                               "python -m pip install -r requirements.txt") from exc
        self.psutil = psutil

    def adapters(self) -> dict[str, bool]:
        try:
            return {name: stats.isup for name, stats in self.psutil.net_if_stats().items()}
        except (self.psutil.Error, OSError) as exc:
            raise RuntimeError(f"Не удалось прочитать состояние адаптеров: {exc}") from exc

    def read(self, selected: tuple[str, ...]) -> dict[str, Counters]:
        active = self.adapters()
        # Raw counters let us detect resets; psutil's nowrap cache would hide them.
        try:
            counters = self.psutil.net_io_counters(pernic=True, nowrap=False)
        except (self.psutil.Error, OSError) as exc:
            raise RuntimeError(f"Не удалось прочитать сетевые счётчики: {exc}") from exc
        if counters is None:
            raise RuntimeError("Windows не вернула сетевые счётчики.")
        return {name: Counters(stats.bytes_recv, stats.bytes_sent)
                for name, stats in counters.items()
                if active.get(name, False) and (not selected or name in selected)}


@dataclass
class Settings:
    adapters: tuple[str, ...] = ()
    interval: float = 1.0
    csv_path: Path | None = None


def parse_interval(value: str) -> float:
    try:
        interval = float(value.replace(",", "."))
    except ValueError as exc:
        raise ValueError("Укажите интервал от 0,1 до 3600 секунд.") from exc
    if not math.isfinite(interval) or not 0.1 <= interval <= 3600:
        raise ValueError("Укажите интервал от 0,1 до 3600 секунд.")
    return interval


def validate_csv(path: Path) -> None:
    if path.exists():
        raise ValueError(f"Файл уже существует: {path}. Укажите новое имя.")
    if not path.parent.is_dir():
        raise ValueError(f"Каталог не существует: {path.parent}")


def format_amount(value: float, per_second: bool = False) -> str:
    units = ("Б", "КиБ", "МиБ", "ГиБ", "ТиБ")
    index = 0
    while value >= 1024 and index < len(units) - 1:
        value /= 1024
        index += 1
    return f"{value:.2f} {units[index]}" + ("/с" if per_second else "")


def dashboard_lines(rows: list[Measurement], settings: Settings, interactive: bool = True) -> list[str]:
    stop_hint = "Q / Esc — меню" if interactive else "Ctrl+C — остановить мониторинг"
    lines = [f"СЕТЕВОЙ ТРАФИК  |  {datetime.now():%H:%M:%S}",
             f"{stop_hint}  |  Интервал: {settings.interval:g} с",
             f"CSV: {settings.csv_path or 'выключен'}",
             "Входящий = получено; исходящий = отправлено. Итоги за этот запуск.", ""]
    if not rows:
        lines.append("Нет выбранных активных адаптеров. Ожидание подключения...")
    for row in rows:
        lines.extend([f"[{row.adapter}]",
                      f"  ВХОДЯЩИЙ   {format_amount(row.received_rate, True):<18} Всего: {format_amount(row.received_total)}",
                      f"  ИСХОДЯЩИЙ  {format_amount(row.sent_rate, True):<18} Всего: {format_amount(row.sent_total)}"])
        if row.reset:
            lines.append("  Счётчик сброшен; прирост сброшенного направления пропущен.")
        lines.append("")
    return lines


def bounded_frame(lines: list[str], width: int, height: int) -> str:
    width, height = max(1, width - 1), max(1, height - 1)
    visible = lines[:height]
    if len(lines) > height:
        visible[-1] = "... Увеличьте окно, чтобы видеть все адаптеры."
    return "\n".join(line if len(line) <= width else line[:width - 1] + "…"
                     for line in visible)


class Console:
    def __init__(self) -> None:
        import msvcrt
        self.keyboard = msvcrt
        self.original_mode = None

    def __enter__(self):
        kernel = ctypes.windll.kernel32
        # Explicit handle types avoid truncating 64-bit Windows handles.
        kernel.GetStdHandle.restype = ctypes.c_void_p
        kernel.GetConsoleMode.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel.SetConsoleMode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.handle = kernel.GetStdHandle(-11)
        mode = ctypes.c_ulong()
        if not kernel.GetConsoleMode(self.handle, ctypes.byref(mode)):
            raise RuntimeError("Не удалось открыть консоль. Запустите CMD-файл в обычном терминале.")
        self.original_mode = mode.value
        if not kernel.SetConsoleMode(self.handle, mode.value | 0x0004):
            raise RuntimeError("Консоль не поддерживает обновление панели.")
        print("\x1b[?1049h\x1b[?25l", end="", flush=True)
        return self

    def __exit__(self, *_):
        print("\x1b[?25h\x1b[?1049l", end="", flush=True)
        if self.original_mode is not None:
            ctypes.windll.kernel32.SetConsoleMode(self.handle, self.original_mode)

    def show(self, lines: list[str]) -> None:
        size = shutil.get_terminal_size((100, 30))
        print("\x1b[H\x1b[2J" + bounded_frame(lines, size.columns, size.lines), end="", flush=True)

    def ask(self, prompt: str) -> str:
        print("\x1b[?25h", end="", flush=True)
        try:
            return input("\n" + prompt + ": ").strip()
        finally:
            print("\x1b[?25l", end="", flush=True)

    def stop_pressed(self) -> bool:
        while self.keyboard.kbhit():
            key = self.keyboard.getwch()
            if key in ("\x00", "\xe0"):
                # Consume extended-key suffix: Home must not be interpreted as Q.
                self.keyboard.getwch()
            elif key.lower() == "q" or key == "\x1b":
                return True
        return False


def wait_interval(seconds, stop, clock=time.monotonic, sleep=time.sleep) -> bool:
    deadline = clock() + seconds
    while True:
        if stop():
            return True
        remaining = deadline - clock()
        if remaining <= 0:
            return False
        sleep(min(0.05, remaining))


def monitor(settings: Settings, backend, samples: int = 0, console=None,
            clock=time.monotonic, sleep=time.sleep) -> None:
    missing = set(settings.adapters) - backend.adapters().keys()
    if missing:
        raise ValueError("Адаптеры не найдены: " + ", ".join(sorted(missing)))
    if settings.csv_path:
        validate_csv(settings.csv_path)
    state = TrafficState()
    counters = backend.read(settings.adapters)
    state.update(counters, clock())
    if console:
        console.show(dashboard_lines([], settings) + ["Подготовка первого измерения..."])
    output = writer = None
    completed = 0
    try:
        while samples == 0 or completed < samples:
            if console:
                if wait_interval(settings.interval, console.stop_pressed, clock, sleep):
                    break
            else:
                sleep(settings.interval)
            rows = state.update(backend.read(settings.adapters), clock())
            if console:
                console.show(dashboard_lines(rows, settings))
            else:
                print("\n".join(dashboard_lines(rows, settings, interactive=False)))
            if rows and settings.csv_path:
                if output is None:
                    output = settings.csv_path.open("x", encoding="utf-8-sig", newline="")
                    writer = csv.DictWriter(output, fieldnames=CSV_FIELDS)
                    writer.writeheader()
                writer.writerows(row.csv_record() for row in rows)
                output.flush()
            completed += 1
    finally:
        if output is not None:
            output.close()


def menu(backend, console, on_monitor) -> None:
    settings = Settings()
    while True:
        console.show(["СЕТЕВОЙ ТРАФИК — главное меню", "",
                      "Адаптеры: " + (", ".join(settings.adapters) or "все активные"),
                      f"Интервал: {settings.interval:g} с", f"CSV: {settings.csv_path or 'выключен'}", "",
                      "1  Начать мониторинг", "2  Выбрать адаптеры", "3  Настроить интервал",
                      "4  Запись CSV: включить / выключить", "5  Справка", "0  Выход"])
        try:
            choice = console.ask("Ваш выбор")
            if choice == "0":
                return
            if choice == "1":
                try:
                    on_monitor(settings)
                except KeyboardInterrupt:
                    pass
            elif choice == "2":
                adapters = sorted(backend.adapters().items())
                console.show(["ВЫБОР АДАПТЕРОВ", "0  Все активные"] +
                             [f"{i}  {name} ({'активен' if up else 'отключён'})"
                              for i, (name, up) in enumerate(adapters, 1)])
                answer = console.ask("Номера через запятую; Enter — отмена")
                if answer == "0":
                    settings.adapters = ()
                elif answer:
                    numbers = [int(part.strip()) for part in answer.split(",")]
                    if any(n < 1 or n > len(adapters) for n in numbers):
                        raise ValueError("Выберите номера из списка.")
                    settings.adapters = tuple(dict.fromkeys(adapters[n - 1][0] for n in numbers))
            elif choice == "3":
                answer = console.ask("Интервал от 0,1 до 3600 с; Enter — отмена")
                if answer:
                    settings.interval = parse_interval(answer)
            elif choice == "4":
                if settings.csv_path:
                    settings.csv_path = None
                else:
                    answer = console.ask("Путь к новому CSV; Enter — отмена")
                    if answer:
                        path = Path(answer).expanduser().absolute()
                        validate_csv(path)
                        settings.csv_path = path
            elif choice == "5":
                console.show(["СПРАВКА", "Системные счётчики активных сетевых адаптеров.",
                              "Скорость — Б/с, КиБ/с, МиБ/с. Объём — за текущий запуск.",
                              "Q / Esc — меню. Каждый старт обнуляет итоги.",
                              "CSV: байты и байты/с; для нового запуска выберите новый файл.",
                              "Трафик включает локальную сеть, без разбивки по процессам.",
                              "Виртуальные интерфейсы могут учитывать поток повторно."])
                console.ask("Enter — вернуться")
            else:
                raise ValueError("Выберите пункт от 0 до 5.")
        except (OSError, ValueError, RuntimeError) as exc:
            console.show([f"Ошибка: {exc}"])
            console.ask("Enter — вернуться в меню")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Входящий и исходящий трафик адаптеров Windows 11")
    parser.add_argument("--interactive", action="store_true", help="главное меню")
    parser.add_argument("--adapter", action="append", default=[], help="точное имя адаптера; можно повторять")
    parser.add_argument("--interval", default="1", help="интервал от 0.1 до 3600 секунд")
    parser.add_argument("--samples", type=int, default=0, help="число измерений; 0 — без ограничения")
    parser.add_argument("--csv", type=Path, help="новый CSV-файл")
    args = parser.parse_args(argv)
    try:
        if args.samples < 0:
            raise ValueError("Число измерений не может быть отрицательным.")
        settings = Settings(tuple(args.adapter), parse_interval(args.interval), args.csv)
        backend = WindowsAdapters()
        if args.interactive:
            if not sys.stdin.isatty() or not sys.stdout.isatty():
                raise RuntimeError("Меню требует обычной консоли без перенаправления ввода/вывода.")
            with Console() as console:
                menu(backend, console, lambda config: monitor(config, backend, console=console))
        else:
            monitor(settings, backend, args.samples)
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        return 0


if __name__ == "__main__":
    if sys.version_info < (3, 10):
        print("Требуется Python 3.10 или новее.", file=sys.stderr)
        sys.exit(1)
    sys.exit(main())
