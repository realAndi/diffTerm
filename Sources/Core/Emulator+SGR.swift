import Foundation

extension Emulator {

    /// SGR — Select Graphic Rendition. Handles both the legacy semicolon form
    /// (`38;2;r;g;b`) and the ITU-T T.416 colon form (`38:2::r:g:b`) that
    /// modern programs emit, because getting only one of them right is the
    /// usual reason truecolor output comes out wrong.
    func applySGR(_ params: ParamList) {
        if params.isEmpty {
            attrs = .blank
            currentLinkID = 0
            return
        }

        var i = 0
        while i < params.count {
            let code = params.at(i)

            // Extended colour, colon form: all components are sub-parameters
            // of this one parameter, so it never consumes following params.
            if (code == 38 || code == 48 || code == 58), params.subCount(i) > 1 {
                if let color = parseColonColor(params, at: i) {
                    assign(color: color, for: code)
                }
                i += 1
                continue
            }

            // Extended colour, semicolon form: components follow as separate
            // parameters and must be consumed here.
            if code == 38 || code == 48 || code == 58 {
                let kind = params.at(i + 1)
                if kind == 2, i + 4 < params.count {
                    assign(color: .rgb(clamp8(params.at(i + 2)),
                                       clamp8(params.at(i + 3)),
                                       clamp8(params.at(i + 4))), for: code)
                    i += 5
                    continue
                } else if kind == 5, i + 2 < params.count {
                    assign(color: .indexed(clamp8(params.at(i + 2))), for: code)
                    i += 3
                    continue
                }
                i += 1
                continue
            }

            // `4:3` and friends select an underline style rather than
            // simply turning underlining on.
            if code == 4, params.subCount(i) > 1 {
                applyUnderlineStyle(params.sub(i, 1, default: 1))
                i += 1
                continue
            }

            applySimpleSGR(code)
            i += 1
        }
    }

    private func clamp8(_ v: Int) -> UInt8 {
        UInt8(min(max(v, 0), 255))
    }

    private func assign(color: TermColor, for code: Int) {
        switch code {
        case 38: attrs.fg = color
        case 48: attrs.bg = color
        case 58: attrs.underlineColor = color
        default: break
        }
    }

    /// `38:2:<colorspace>:r:g:b` or `38:2:r:g:b` (the colourspace slot is
    /// optional in the wild) and `38:5:<index>`.
    private func parseColonColor(_ params: ParamList, at i: Int) -> TermColor? {
        let kind = params.sub(i, 1, default: -1)
        switch kind {
        case 2:
            let n = params.subCount(i)
            if n >= 6 {
                return .rgb(clamp8(params.sub(i, 3)), clamp8(params.sub(i, 4)), clamp8(params.sub(i, 5)))
            } else if n == 5 {
                return .rgb(clamp8(params.sub(i, 2)), clamp8(params.sub(i, 3)), clamp8(params.sub(i, 4)))
            }
            return nil
        case 5:
            return .indexed(clamp8(params.sub(i, 2)))
        case 0:
            return TermColor.default
        default:
            return nil
        }
    }

    private func applySimpleSGR(_ code: Int) {
        switch code {
        case 0:
            attrs = .blank
            currentLinkID = 0
        case 1:  attrs.flags.insert(.bold)
        case 2:  attrs.flags.insert(.faint)
        case 3:  attrs.flags.insert(.italic)
        case 4:
            attrs.flags.remove([.doubleUnderline, .curlyUnderline])
            attrs.flags.insert(.underline)
        case 5, 6: attrs.flags.insert(.blink)
        case 7:  attrs.flags.insert(.inverse)
        case 8:  attrs.flags.insert(.invisible)
        case 9:  attrs.flags.insert(.strikethrough)
        case 21:
            attrs.flags.remove([.underline, .curlyUnderline])
            attrs.flags.insert(.doubleUnderline)
        case 22: attrs.flags.remove([.bold, .faint])
        case 23: attrs.flags.remove(.italic)
        case 24: attrs.flags.remove([.underline, .doubleUnderline, .curlyUnderline])
        case 25: attrs.flags.remove(.blink)
        case 27: attrs.flags.remove(.inverse)
        case 28: attrs.flags.remove(.invisible)
        case 29: attrs.flags.remove(.strikethrough)
        case 30...37: attrs.fg = .indexed(UInt8(code - 30))
        case 39: attrs.fg = .default
        case 40...47: attrs.bg = .indexed(UInt8(code - 40))
        case 49: attrs.bg = .default
        case 53: attrs.flags.insert(.overline)
        case 55: attrs.flags.remove(.overline)
        case 59: attrs.underlineColor = .default
        case 90...97:  attrs.fg = .indexed(UInt8(code - 90 + 8))
        case 100...107: attrs.bg = .indexed(UInt8(code - 100 + 8))
        default: break
        }
    }

    /// SGR 4:3 (curly) and friends arrive as sub-parameters of code 4.
    func applyUnderlineStyle(_ style: Int) {
        attrs.flags.remove([.underline, .doubleUnderline, .curlyUnderline])
        switch style {
        case 0: break
        case 2: attrs.flags.insert(.doubleUnderline)
        case 3, 4, 5: attrs.flags.insert(.curlyUnderline)
        default: attrs.flags.insert(.underline)
        }
    }
}
