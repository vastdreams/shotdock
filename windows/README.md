# ShotDock for Windows: plan

The macOS app uses Cocoa, Accessibility and ScreenCaptureKit-era APIs, so Windows needs its own front end.

| Piece | Windows approach | Status |
|---|---|---|
| Claim checker | `claimcheck/claimcheck.py` runs as is (keys from environment variables or the credentials file) | works |
| Overlay and hub | .NET 8 WinUI 3 tray app, always-on-top window | planned |
| Screenshot / window / record | Windows.Graphics.Capture | planned |
| Element pick | UI Automation (`AutomationElement.FromPoint`) | planned |
| Sending into Cursor | UI Automation focus + clipboard paste, same safety rules (empty box only) | planned |
| Install | signed MSIX or `winget`, Ed25519-verified updates | planned |
