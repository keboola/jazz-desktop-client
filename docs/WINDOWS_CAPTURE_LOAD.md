# Windows capture load check

`windows/qualification/Measure-CaptureLoad.ps1` measures how much load Jazz Capture puts on a Windows computer while it records. Microsoft Defender scans every new file, so the number of files that the client creates per user action is the main number to watch.

## How to run it

1. Install the candidate build and start a capture.
2. In a PowerShell window of the same user, run `.\Measure-CaptureLoad.ps1 -DurationSeconds 60 -ReportPath .\load-<version>.json -Label <version>`.
3. During the 60 seconds, use the computer in a fixed way. The reference test: 200 left clicks into a browser page, one click every 250 ms.
4. Run the same test on the same machine with the previous release. Compare `createdTotal`, `createdByKind` and the CPU values.

The CPU values are averages of `% Processor Time` for one core, so a value can be above 100 on a computer with more cores.

## Reference result

Windows 11 Enterprise 26300 in VirtualBox, 2 cores, Defender real-time protection on, release 0.26.26, 21 Nov 2026, 200 clicks in 50 s:

| Created files | Journal WAL | Spool events | Screenshots | JazzCapture CPU | Defender CPU | Disk writes/s |
|---|---|---|---|---|---|---|
| 737 | 499 | 84 files, 77 folders | 77 | 16.6 % | 24.3 % | 52.1 |

About 3.7 new files per click. The journal writes most of them, because it writes and flushes each change as its own file.
