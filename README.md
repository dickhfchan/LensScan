# LensScan

A Microsoft Lens replacement for iOS. Capture a document with the camera, get back a
flat, well-lit, sharpened scan with searchable text and a shareable PDF. Everything
runs on device — no account, no upload.

Target: iOS 17+, Swift 5, SwiftUI.

## Opening the project

There's no `.xcodeproj` checked in. Generate one with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd LensScan
xcodegen generate
open LensScan.xcodeproj
```

If you'd rather not use XcodeGen, create a new iOS App project in Xcode named
`LensScan`, drag the `Sources` folder in, and add an `NSCameraUsageDescription` entry
to the Info.plist.

**You need a real device.** `VNDocumentCameraViewController` is not available on the
Simulator; the app shows an alert there instead of a camera.

## The pipeline

This is the same five-stage shape Lens used, with stages 1–3 handed to Apple's
document camera and stages 4–5 written here.

| Stage | Where it lives | What happens |
|---|---|---|
| 1. Capture | `Scanner/DocumentScannerView.swift` | VisionKit's camera, with live edge overlay and auto-shutter |
| 2. Edge detection | VisionKit | Finds the page's four corners in the preview |
| 3. Perspective correction | VisionKit | Warps those corners into a flat rectangle |
| 4. Enhancement | `Processing/ImageEnhancer.swift` | Shadow removal, tone shaping, sharpening |
| 5. OCR + export | `Processing/OCRService.swift`, `Export/PDFExporter.swift` | On-device text recognition, searchable PDF |

### Why the enhancement works

The interesting part of stage 4 is illumination flattening. Dividing the image by a
heavily blurred copy of itself estimates the local background brightness and cancels
it, which removes the shadow gradient you get from your own hand or a desk lamp. Once
the paper is uniformly white, contrast and tone curves behave predictably — which is
why naive "just crank the contrast" filters look bad on real photos and this doesn't.

The blur radius has to be much larger than the text strokes. Too small and the text
gets treated as background and washes out. The current fractions (5% of the long edge
for documents, 8% for whiteboards) are a reasonable starting point but are worth
tuning against your own sample photos.

Three modes:

- **Document** — flatten, desaturate, hard tone curve, sharpen. Black ink on white paper.
- **Whiteboard** — flatten with a wider radius, then *boost* saturation so marker colors survive.
- **Photo** — no flattening; mild contrast and sharpening only. For receipts and book pages with images.

The original capture is the only thing stored on disk. Modes are re-rendered on
demand, so switching a page from Document to Photo never degrades it and never costs
extra storage.

### Why the PDF is searchable

`PDFExporter` draws the enhanced image, then draws each recognized line on top of it
in `UIColor.clear`, positioned using the normalized bounding box Vision returned. The
glyphs are in the PDF content stream but invisible, so Preview, Spotlight and any PDF
reader can select and search the text while the page still looks like a scan. Font
size is fitted to each box so selection highlights line up with the ink.

Pages are sized assuming 200 DPI, which puts a typical 1700×2200px capture on a
US Letter page.

## File layout

```
Sources/
  App/LensScanApp.swift              entry point
  Models/Scan.swift                  ScanDocument, ScanPage, TextBlock, EnhancementMode
  Store/ScanStore.swift              disk persistence, OCR orchestration
  Scanner/DocumentScannerView.swift  VisionKit wrapper
  Processing/ImageEnhancer.swift     Core Image enhancement pipeline
  Processing/OCRService.swift        Vision text recognition
  Export/PDFExporter.swift           searchable PDF + plain text export
  Views/LibraryView.swift            scan list
  Views/ScanDetailView.swift         page viewer, mode picker, export menu
  Views/ShareSheet.swift             UIActivityViewController wrapper
```

Scans live in `Application Support/Scans/`, with an `index.json` listing documents and
one folder of JPEGs per document.

## OCR languages

`OCRService.preferredLanguages` defaults to `["en-US", "zh-Hans"]`. Vision gets
noticeably less accurate the more languages you give it, so keep this list short.
Unsupported values are filtered out automatically against the current OS revision.

## Known gaps

- No reordering of pages, and no adding pages to an existing scan.
- No search across the library, though the text is already indexed per page.
- No iCloud sync. `ScanStore` writes to Application Support; pointing it at a
  `NSUbiquitousContainer` or swapping in SwiftData would be the path.
- Business-card and table modes from Lens aren't implemented.
- OCR runs page by page on the main actor's task; for 20-page batches it's worth
  moving to a `TaskGroup` with a concurrency limit.

## Where to differentiate

VisionKit gives everyone the same baseline, so the scanner itself isn't a product.
Realistic angles:

1. **Hard captures** — crumpled receipts, curved book spines (dewarping), low-contrast
   white-on-white. This is where a custom segmentation model beats the platform API.
2. **What happens after the scan** — auto-filing by content, expense extraction from
   receipts, turning lecture notes into structured study material.
3. **Privacy and offline** — a genuine differentiator against the cloud scanners, and
   this codebase already has it.
4. **Export targets Lens never had** — direct-to-Obsidian, Notion, or a self-hosted
   document store.

If you want the custom pipeline eventually, the seam is `DocumentScannerView`: replace
it with an AVFoundation capture session plus your own corner detection, and keep
everything downstream unchanged.
