SC4 Shot Collector 1.2.0

Native Apple Silicon Mac app for SC4 2188 (D3:71:43:B6:CC:0C), macOS 13 or later.
Run dist/SC4 Shot Collector.app. Select English in the language menu at the top right.

Connect and collect
1. Turn on SC4 near your Mac and disconnect any other app using it.
2. Allow Bluetooth access when macOS asks, then use Connect Device if needed.
3. New shots are appended to the local record file. The table includes Launch Direction, Apex and Smash Factor.
4. Smash Factor is calculated as ball speed divided by club speed. Its source is identified in exports.

Language and units
- Switch Korean/English and m/yd from the main window or the flight replay window.
- Preferences persist across launches. Distance conversion applies to carry, total, apex, current height, roll distance and chart grid marks. Speed retains its recorded unit.
- CSV/JSON exports include the additional metrics and use the selected distance unit. Original stored records and raw packets remain unchanged.
- Saved records from older versions recover direction from validated raw packets and calculate smash from recorded speeds without rewriting the source file.
- Editable language files: Resources/en.lproj/Localizable.strings and Resources/ko.lproj/Localizable.strings. Keep numbered placeholders intact.

Flight replay
In 3D View, click and drag the ground to orbit horizontally and tilt vertically. Reset View restores the starting angle. Side and Top views remain fixed; returning to 3D restores your adjusted angle. Camera changes do not alter shot data or playback position.
Select a shot and click Flight Simulation. Play/pause, scrub, change speed or choose 3D, Side View or Top View. Auto-play New Shots follows new live measurements.
The trajectory is fitted to recorded carry, apex and valid launch angle. Timing is estimated. Wind, aerodynamic drag and spin curvature are not modeled; roll timing is illustrative.

Record preservation
Data: ~/Library/Application Support/SC4 Shot Collector/shots.jsonl
Raw notifications: shot-transport.jsonl in the same directory.
Storage is append-only. Exports refuse to overwrite existing files.
Only device-information queries (0x64) and live-fragment acknowledgements (0x73) can be sent. Delete, settings and history-query commands are blocked.
An earlier history download reduced the reported device count from 68 to 0; the query can consume its queue. History downloading has been removed. Previously received records remain on the Mac. Physical flash erasure and live-ACK effects on device retention have not been established.

Build: zsh build.sh
Tests: zsh test-all.sh [optional path to saved shots.jsonl]

Repository fixtures are synthetic. No personal shot journal or user BLE capture is included.
