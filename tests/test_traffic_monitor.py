import copy
import csv
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import traffic_monitor as app


class FakeBackend:
    def __init__(self, snapshots=()):
        self.snapshots = iter(snapshots)

    def adapters(self):
        return {"Ethernet": True, "Wi-Fi": False}

    def read(self, selected):
        return next(self.snapshots)


class FakeConsole:
    def __init__(self, answers=(), stop=False):
        self.answers = iter(answers)
        self.frames = []
        self.stop = stop

    def ask(self, prompt):
        return next(self.answers)

    def show(self, lines):
        self.frames.append(lines)

    def stop_pressed(self):
        return self.stop


class AccountingTests(unittest.TestCase):
    def test_elapsed_time_independent_totals_and_large_integer_precision(self):
        state = app.TrafficState()
        big = 2**60
        rows = state.update({"Ethernet": app.Counters(1000, 2000), "Wi-Fi": app.Counters(big, 0)}, 0)
        self.assertEqual(rows[0].received_total, 0)
        rows = state.update({"Ethernet": app.Counters(1500, 2250), "Wi-Fi": app.Counters(big + 1, 4)}, 2.5)
        self.assertEqual(rows[0].received_rate, 200)
        self.assertEqual(rows[0].sent_rate, 100)
        self.assertEqual(rows[1].received_delta, 1)
        self.assertEqual(rows[1].received_total, 1)

    def test_reset_disconnect_and_reconnect(self):
        state = app.TrafficState()
        state.update({"Ethernet": app.Counters(1000, 1000)}, 0)
        state.update({"Ethernet": app.Counters(1500, 1200)}, 1)
        row = state.update({"Ethernet": app.Counters(20, 1300)}, 2)[0]
        self.assertTrue(row.reset)
        self.assertEqual((row.received_delta, row.sent_delta), (0, 100))
        self.assertEqual(row.received_total, 500)
        self.assertEqual(state.update({}, 3), [])
        row = state.update({"Ethernet": app.Counters(9000, 9000)}, 4)[0]
        self.assertEqual(row.received_rate, 0)
        self.assertEqual(row.received_total, 500)
        row = state.update({"Ethernet": app.Counters(9125, 9250)}, 5.25)[0]
        self.assertEqual((row.received_rate, row.sent_rate), (100, 200))

    def test_nonincreasing_time_and_negative_counters_rejected(self):
        state = app.TrafficState()
        state.update({"Ethernet": app.Counters(1, 1)}, 0)
        with self.assertRaises(ValueError):
            state.update({"Ethernet": app.Counters(2, 2)}, 0)
        with self.assertRaises(ValueError):
            app.TrafficState().update({"Ethernet": app.Counters(-1, 0)}, 0)


class NativeBackendTests(unittest.TestCase):
    def test_raw_counters_active_filter_and_exact_selection(self):
        backend = app.WindowsAdapters.__new__(app.WindowsAdapters)
        backend.psutil = Mock()
        backend.psutil.net_if_stats.return_value = {
            "Ethernet": SimpleNamespace(isup=True), "Wi-Fi": SimpleNamespace(isup=False),
            "Тест [1]": SimpleNamespace(isup=True)}
        backend.psutil.net_io_counters.return_value = {
            name: SimpleNamespace(bytes_recv=10, bytes_sent=20)
            for name in ("Ethernet", "Wi-Fi", "Тест [1]")}
        self.assertEqual(set(backend.read(())), {"Ethernet", "Тест [1]"})
        self.assertEqual(set(backend.read(("Тест [1]",))), {"Тест [1]"})
        backend.psutil.net_io_counters.assert_called_with(pernic=True, nowrap=False)

    def test_missing_dependency_is_actionable(self):
        with patch.object(app.sys, "platform", "win32"), patch.dict("sys.modules", {"psutil": None}):
            with self.assertRaisesRegex(RuntimeError, "pip install -r requirements.txt"):
                app.WindowsAdapters()

    def test_native_access_failure_is_shown_safely(self):
        backend = app.WindowsAdapters.__new__(app.WindowsAdapters)
        backend.psutil = Mock(Error=RuntimeError)
        backend.psutil.net_if_stats.side_effect = RuntimeError("access denied")
        with self.assertRaisesRegex(RuntimeError, "состояние адаптеров"):
            backend.adapters()


class ConsoleTests(unittest.TestCase):
    def test_adaptive_units_reset_and_disconnected_state(self):
        self.assertEqual(app.format_amount(1024, True), "1.00 КиБ/с")
        self.assertEqual(app.format_amount(1073741824), "1.00 ГиБ")
        row = app.Measurement("", "Тест", 2048, 1048576, 4096, 1073741824, 0, 0, True)
        frame = "\n".join(app.dashboard_lines([row], app.Settings()))
        for text in ("Тест", "ВХОДЯЩИЙ", "ИСХОДЯЩИЙ", "КиБ/с", "МиБ/с", "Всего", "сброшен"):
            self.assertIn(text, frame)
        self.assertIn("Ожидание подключения", "\n".join(app.dashboard_lines([], app.Settings())))

    def test_bounded_frame_does_not_wrap_or_scroll(self):
        frame = app.bounded_frame(["x" * 200] * 100, 30, 10)
        self.assertEqual(len(frame.splitlines()), 9)
        self.assertTrue(all(len(line) <= 29 for line in frame.splitlines()))
        self.assertEqual(app.bounded_frame(["abc", "def"], 1, 1), "…")

    def test_interval_rejects_nan_infinity_and_range(self):
        self.assertEqual(app.parse_interval("0,25"), 0.25)
        for invalid in ("bad", "nan", "inf", "0", "3601"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                app.parse_interval(invalid)

    def test_menu_navigation_settings_errors_help_and_return(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "новый файл.csv"
            console = FakeConsole(["2", "2", "3", "bad", "", "3", "0,25", "4", str(path),
                                   "1", "4", "2", "0", "1", "5", "", "0"])
            snapshots = []
            app.menu(FakeBackend(), console, lambda settings: snapshots.append(copy.deepcopy(settings)))
            self.assertEqual(len(snapshots), 2)
            self.assertEqual(snapshots[0], app.Settings(("Wi-Fi",), 0.25, path))
            self.assertEqual(snapshots[1], app.Settings((), 0.25, None))
            frames = "\n".join(line for frame in console.frames for line in frame)
            self.assertIn("Ошибка:", frames)
            self.assertIn("без разбивки по процессам", frames)

    def test_monitor_failure_returns_to_menu(self):
        console = FakeConsole(["1", "", "0"])
        app.menu(FakeBackend(), console, Mock(side_effect=OSError("test failure")))
        self.assertTrue(any("test failure" in line for frame in console.frames for line in frame))

    def test_q_escape_and_extended_keys(self):
        console = app.Console.__new__(app.Console)
        for keys, expected in ((["Q"], True), (["\x1b"], True), (["\xe0", "q"], False)):
            with self.subTest(keys=keys):
                sequence = iter(keys)
                console.keyboard = SimpleNamespace(kbhit=Mock(side_effect=[True, False]), getwch=lambda: next(sequence))
                self.assertEqual(console.stop_pressed(), expected)

    def test_wait_interrupts_long_interval_without_sleep(self):
        sleeper = Mock()
        self.assertTrue(app.wait_interval(3600, lambda: True, lambda: 0, sleeper))
        sleeper.assert_not_called()


class MonitorTests(unittest.TestCase):
    def test_finite_samples_csv_real_elapsed_and_unicode_path(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "трафик с пробелом.csv"
            backend = FakeBackend([{"Ethernet": app.Counters(1000, 1000)},
                                   {"Ethernet": app.Counters(1500, 1250)},
                                   {"Ethernet": app.Counters(1600, 1300)}])
            ticks = iter([0, 2.5, 3.5])
            with patch("sys.stdout", new=io.StringIO()) as screen:
                app.monitor(app.Settings(csv_path=path), backend, 2, clock=lambda: next(ticks), sleep=lambda _: None)
            self.assertIn("Ctrl+C", screen.getvalue())
            self.assertNotIn("Q / Esc", screen.getvalue())
            with path.open(encoding="utf-8-sig", newline="") as output:
                rows = list(csv.DictReader(output))
            self.assertEqual(len(rows), 2)
            self.assertEqual(tuple(rows[0]), app.CSV_FIELDS)
            self.assertEqual(float(rows[0]["ReceivedBytesPerSecond"]), 200)
            self.assertEqual(int(rows[1]["SessionReceivedBytes"]), 600)
            self.assertIn("T", rows[0]["Timestamp"])
            with self.assertRaises(ValueError):
                app.monitor(app.Settings(csv_path=path), FakeBackend(), 1)

    def test_no_active_adapter_leaves_csv_uncreated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "empty.csv"
            ticks = iter([0, 1])
            with patch("sys.stdout", new=io.StringIO()):
                app.monitor(app.Settings(csv_path=path), FakeBackend([{}, {}]), 1,
                            clock=lambda: next(ticks), sleep=lambda _: None)
            self.assertFalse(path.exists())

    def test_q_returns_before_first_sample(self):
        backend = FakeBackend([{"Ethernet": app.Counters(1, 1)}])
        console = FakeConsole(stop=True)
        app.monitor(app.Settings(interval=3600), backend, console=console, clock=lambda: 0)
        self.assertEqual(len(console.frames), 1)

    def test_missing_adapter_and_bad_cli_input(self):
        with self.assertRaises(ValueError):
            app.monitor(app.Settings(("missing",)), FakeBackend(), 1)
        with patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(app.main(["--samples", "-1"]), 1)
            self.assertEqual(app.main(["--interval", "nan"]), 1)


if __name__ == "__main__":
    unittest.main()
