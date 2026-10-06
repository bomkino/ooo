import Foundation

/// Finds the figures on a slide (charts, diagrams, pictures) from its ink:
/// the places with edges that are not text. On slides this beats general
/// saliency, which tends to call the whole slide, or a paragraph and the
/// white space around it, the thing worth a look.
public enum FigureFinder {
    /// `luma` is the slide in grey, 0…1, row by row from the top. `text` are
    /// the lines of text as (u0, v0, u1, v1) in slide space (v down). Returns
    /// each figure's bounds in slide space, largest first.
    public static func figures(luma: [Float], width w: Int, height h: Int, text: [SIMD4<Float>],
                               cell: Int = 8, threshold: Float = 0.08) -> [SIMD4<Float>] {
        guard w > 2, h > 2, cell > 0, luma.count >= w * h else { return [] }
        let W = Float(w), H = Float(h)

        // Text is read, not looked at: mask each line with a little room.
        var masked = [Bool](repeating: false, count: w * h)
        for t in text {
            let pad = H * (t.w - t.y) * 0.4
            let x0 = max(0, Int(t.x * W - pad)), x1 = min(w - 1, Int(t.z * W + pad))
            let y0 = max(0, Int(t.y * H - pad)), y1 = min(h - 1, Int(t.w * H + pad))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { masked[y * w + x] = true } }
        }

        // Edges outside text, counted per cell.
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var counts = [Int](repeating: 0, count: gw * gh)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                if masked[i] { continue }
                let g = abs(luma[i + 1] - luma[i - 1]) + abs(luma[i + w] - luma[i - w])
                if g > threshold { counts[(y / cell) * gw + x / cell] += 1 }
            }
        }
        let ink = counts.map { $0 >= 2 }

        // Strokes that nearly touch belong together: grow by one cell, then
        // gather 8-connected regions.
        var grown = ink
        for gy in 0..<gh {
            for gx in 0..<gw where ink[gy * gw + gx] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = gx + dx, ny = gy + dy
                        if nx >= 0, ny >= 0, nx < gw, ny < gh { grown[ny * gw + nx] = true }
                    }
                }
            }
        }
        var seen = [Bool](repeating: false, count: gw * gh)
        var out: [SIMD4<Float>] = []
        for start in 0..<(gw * gh) where grown[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var lo = SIMD2<Int>(Int.max, Int.max), hi = SIMD2<Int>(Int.min, Int.min)
            var inked = 0
            while let c = stack.popLast() {
                let cx = c % gw, cy = c / gw
                if ink[c] {
                    inked += 1
                    lo = SIMD2(min(lo.x, cx), min(lo.y, cy))
                    hi = SIMD2(max(hi.x, cx), max(hi.y, cy))
                }
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let n = ny * gw + nx
                        if grown[n] && !seen[n] { seen[n] = true; stack.append(n) }
                    }
                }
            }
            guard inked >= 4 else { continue }
            let b = SIMD4<Float>(Float(lo.x * cell) / W, Float(lo.y * cell) / H,
                                 min(1, Float((hi.x + 1) * cell) / W), min(1, Float((hi.y + 1) * cell) / H))
            let du = b.z - b.x, dv = b.w - b.y
            // Specks, rules and ornaments are not figures; neither is the slide.
            if du > 0.03 && dv > 0.04 && du * dv > 0.006 && du * dv < 0.6 { out.append(b) }
        }
        return out.sorted { ($0.z - $0.x) * ($0.w - $0.y) > ($1.z - $1.x) * ($1.w - $1.y) }
    }
}
