import Foundation

/// How a row of attachment chips breaks across lines. A drop can bring in more
/// names than the composer's column is wide.
public enum ChipFlow {

    public struct Line: Equatable, Sendable {
        public var indices: [Int]
        public var width: CGFloat
        public var height: CGFloat
    }

    public static func lines(sizes: [CGSize], spacing: CGFloat, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line(indices: [], width: 0, height: 0)

        for (index, size) in sizes.enumerated() {
            if !line.indices.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line(indices: [], width: 0, height: 0)
            }

            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }

        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }

    public static func height(of lines: [Line], spacing: CGFloat) -> CGFloat {
        lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
    }

    /// Where each chip starts, relative to the top-left of the block.
    public static func origins(of lines: [Line], sizes: [CGSize], spacing: CGFloat) -> [CGPoint] {
        var origins = [CGPoint](repeating: CGPoint(x: 0, y: 0), count: sizes.count)
        var y: CGFloat = 0

        for line in lines {
            var x: CGFloat = 0
            for index in line.indices {
                origins[index] = CGPoint(x: x, y: y)
                x += sizes[index].width + spacing
            }
            y += line.height + spacing
        }

        return origins
    }
}
