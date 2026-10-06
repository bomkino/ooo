# Notices

## The pitch.dog Studio engine

`Sources/RenderCore`, `Sources/BackdropKit` and `Sources/StageKit` are vendored from [bomkino/pitchdog-drift](https://github.com/bomkino/pitchdog-drift) at commit `f058788` (Drift 2.2.0), by the same authors and under the same licence (GNU AGPL 3.0). Drift's scene catalogue (`StageKit/Scenes`, `SamplePaintings.swift`) is left out. `Sources/BackdropKit` was later brought up to [bomkino/backdrop](https://github.com/bomkino/backdrop) commit `98039c7` (Backdrop 2.0.0: Solid, Linear, Radial, Conic, Caustics and Iridescence), whose RenderCore is the same. In OOO 1.0.1, `RenderCore/GPU.swift` (one compile per shader library, shared by every caller) and `StageKit/Media.swift` (mipmaps made on a queue of their own, so loading a slide never waits behind the stage's frames) were brought up to Drift 2.5.0 (`9038f61`). Changes for OOO:

- `CardPose` gains `window` (a texture that holds one region of its media, so a sharp detail can be laid exactly over its card), `edgeScale`, a soft spotlight (`spot`, `spotDim`, `spotFeather`) and `shadowGround` (a cut-out's shadow falls on the sheet it was lifted from).
- `StageRenderer.Request.backdropUV` and the `copy_uv_fragment` shader let the background answer the camera with a touch of parallax.
- The near plane adapts to the camera's distance, so extreme close-ups keep their depth precision.
- `CardPose.softEdge` fades a card's edges (a detail lifted off a slide blends into it), `CardPose.reflects` keeps an overlaid detail out of the mirror floor, and `StageFrame.reflectionFade` and `reflectionBlur` make a soft floor. A soft-edged card casts a diffuse shadow from inside its solid middle.
- `StageFrame.travel(to:width:height:)` measures how far anything in view moves between two frames, in pixels, so motion blur takes only the samples a frame needs.
- `TitleCompositor` is public, with an `encode` that takes the title's opacity and rise directly, for a scene that times its own title.
- `CardPose.surfaceAmount` lets a card's surface light (tooth, sheen, foil, satin) step back, so its media shows as it is. The backdrop adds no alpha to the scene, which leaves the scene's alpha as the cards' coverage, and `FinishFrame.bloomOnSubject` uses it to keep bloom off the cards' faces.
- Depth of field measures depth along the view, so focus lies on a plane.
- `CardPose.ink` lays a mark drawn by hand on its card, drawing on over time. In OOO 1.0.2 it became a glaze: the renderer draws it twice, multiplied in and then screened over, using the new `GPU.Blend` cases `multiply` and `screen`.

Parts of the editor (`Sources/OOOStudio`: the theme, type, controls, live stage, export sheet and document) are adapted from Drift's `StudioKit`, and its headless screenshots (`Snapshot.swift`) from Backdrop's, as marked in each file.

## Sparkle

In-app updates use Sparkle 2.10.0 (github.com/sparkle-project/Sparkle), embedded unchanged as `Contents/Frameworks/Sparkle.framework` with the signature its makers gave it. Copyright (c) 2006–2013 Andy Matuschak and the other authors named in its licence. Released under the MIT License, with the external licences of the code it includes (bsdiff, sais-lite, ed25519 and others); the full text is in `Resources/Licenses/Sparkle-LICENSE.txt`, and in the app at `Contents/Resources/Licenses/Sparkle-LICENSE.txt`. `Sources/Updates/AppUpdates.swift` is Drift's, unchanged.

## webgl-noise

Simplex noise in `Sources/RenderCore/ShaderPrelude.swift` is ported from webgl-noise.

Copyright (C) 2011 Ashima Arts. Copyright (C) 2011–2016 Stefan Gustavson. Released under the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## LUMEN

The Soft Bloom look in `Sources/BackdropKit/BackdropShaders.swift` follows the region structure and distributions of LUMEN's "bloom" mode (Leonxlnx/lumenshaders), re-authored with OKLab over-painting and exact integer orbits.

Copyright (c) 2026 Leonxlnx. Released under the MIT License (text as above).

## Type

No fonts are bundled. The interface is set in the system font. The sample slide is drawn with faces that ship with macOS, by the operating system at render time.

## Research

The camera's maths and the director were written for OOO. They draw on published work and on reading other projects; no code from these is included:

- Jarke J. van Wijk and Wim A. A. Nuij, "Smooth and efficient zooming and panning", IEEE InfoVis 2003 (also the basis of d3-interpolate's `interpolateZoom`).
- Tamar Flash and Neville Hogan, "The coordination of arm movements", Journal of Neuroscience, 1985 (minimum-jerk motion).
- ITU-R BT.1359 on the relative timing of sound and picture.
- Cap, OpenScreen, Recordly, Screenize, Motion Canvas and Theatre.js, for how open-source editors time and ease their cameras; HoloCloth, DialKit and Paper Studio, for material, live tuning and paper. Satin and Foil come to OOO through Drift.
