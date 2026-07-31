// Verifies the text-centring patch (patches/text-centre-anchor-on-ink.patch)
// against mbgl's shaping directly, with no map, no GPU and no fonts.
//
//   cmake -B <build> -DMAPLIBRE_FLUTTER_BUILD_HARNESS=ON && ninja shaping_probe
//   ./shaping_probe
//
// mbgl positions text vertically from `Shaping::yOffset = -17` (of ONE_EM = 24),
// a hardcoded stand-in for font metrics the glyph PBF does not carry. Fonts whose
// real metrics differ therefore render centre-anchored text off-centre. The patch
// centres on the shaped glyphs' actual ink instead.
//
// Synthetic glyph metrics are used deliberately: the assertions then hold for any
// font, and a failure means the algorithm changed rather than that a font did.
// The upstream-facing version of these cases lives in mbgl's own suite at
// test/text/shaping.test.cpp.

#include <mbgl/text/bidi.hpp>
#include <mbgl/text/shaping.hpp>
#include <mbgl/text/tagged_string.hpp>
#include <mbgl/util/constants.hpp>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace mbgl;

namespace {

int failures = 0;

void check(bool ok, const std::string& what, double got, double want) {
    std::printf("%-58s %8.3f (want %7.3f)  %s\n", what.c_str(), got, want, ok ? "ok" : "FAIL");
    if (!ok) ++failures;
}

void near(double got, double want, const std::string& what, double tol = 0.01) {
    check(std::fabs(got - want) <= tol, what, got, want);
}

GlyphPosition inkGlyph(int32_t top, uint32_t height) {
    GlyphPosition position;
    position.metrics.width = 18;
    position.metrics.height = height;
    position.metrics.left = 2;
    position.metrics.top = top;
    position.metrics.advance = 21;
    return position;
}

// Vertical extent of the shaped ink relative to the anchor, derived exactly as
// the quad builder does (quads.cpp: y1 = -metrics.top * scale + glyph.y,
// spanning metrics.height * scale).
std::pair<float, float> inkExtent(const Shaping& shaping) {
    float top = std::numeric_limits<float>::max();
    float bottom = std::numeric_limits<float>::lowest();
    for (const auto& line : shaping.positionedLines) {
        for (const auto& glyph : line.positionedGlyphs) {
            if (glyph.metrics.height == 0) continue;
            const float glyphTop = glyph.y - static_cast<float>(glyph.metrics.top) * glyph.scale;
            top = std::min(top, glyphTop);
            bottom = std::max(bottom, glyphTop + static_cast<float>(glyph.metrics.height) * glyph.scale);
        }
    }
    return {top, bottom};
}

Shaping shapeOneLine(style::SymbolAnchorType anchor, GlyphPosition glyphPosition) {
    Glyph glyph;
    glyph.id = u'A';
    glyph.metrics = glyphPosition.metrics;

    BiDi bidi;
    const std::vector<std::string> fontStack{{"font-stack"}};
    const SectionOptions sectionOptions(1.0f, fontStack, GlyphIDType::FontPBF, 0);
    auto immutableGlyph = Immutable<Glyph>(makeMutable<Glyph>(std::move(glyph)));
    GlyphMap glyphs = {{FontStackHasher()(fontStack), {{u'A', std::move(immutableGlyph)}}}};
    GlyphPositions glyphPositions = {{FontStackHasher()(fontStack), {{u'A', std::move(glyphPosition)}}}};
    ImagePositions imagePositions;

    TaggedString string(u"AA", sectionOptions);
    return getShaping(string,
                      5 * util::ONE_EM,
                      util::ONE_EM, // lineHeight
                      anchor,
                      style::TextJustifyType::Center,
                      0,              // spacing
                      {{0.0f, 0.0f}}, // translate
                      WritingModeType::Horizontal,
                      bidi,
                      glyphs,
                      glyphPositions,
                      imagePositions,
                      16.0f, // layoutTextSize
                      16.0f, // layoutTextSizeAtBucketZoomLevel
                      /*allowVerticalPlacement*/ false);
}

} // namespace

int main() {
    std::printf("shaping_probe — centre-anchored text is centred on its ink\n\n");

    // The case that catches the bug: ink neither as tall as the old constant nor
    // symmetric about it. Unpatched, mbgl centres the layout box and leaves the
    // ink wherever the -17 baseline put it.
    {
        const auto [top, bottom] = inkExtent(shapeOneLine(style::SymbolAnchorType::Center, inkGlyph(11, 11)));
        near(top + bottom, 0.0, "centre anchor, ink 11 up / 11 tall: ink midpoint");
        near(top, -5.5, "  ink top");
        near(bottom, 5.5, "  ink bottom");
    }

    // A tall glyph, to show the result tracks the ink rather than any constant.
    {
        const auto [top, bottom] = inkExtent(shapeOneLine(style::SymbolAnchorType::Center, inkGlyph(22, 30)));
        near(top + bottom, 0.0, "centre anchor, ink 22 up / 30 tall: ink midpoint");
        near(bottom - top, 30.0, "  ink height preserved");
    }

    // The collision box must stay symmetric about the anchor. It is built from
    // top/bottom (collision_feature.cpp), and it was already anchor-centred while
    // the ink was not — so centring the ink brings the two together. Moving the
    // box as well would push them apart again.
    {
        const auto shaping = shapeOneLine(style::SymbolAnchorType::Center, inkGlyph(11, 11));
        near(shaping.top + shaping.bottom, 0.0, "centre anchor: box still symmetric about anchor");
        near(shaping.top, -util::ONE_EM / 2.0, "  box top");
    }

    // Edge anchors are deliberately NOT re-centred: "top"/"bottom" mean "align
    // this edge", so this patch leaves them on the existing code path. Assert
    // their stock values exactly, as a guard that the patch does not leak in.
    //
    // Note for upstreaming: those stock values are themselves skewed by the same
    // -17 constant. With ink rising 11 above the baseline, `text-anchor: top`
    // ought to hang the text BELOW the anchor (roughly 0..+11) and instead puts
    // it at -16..-5. Fixing edge anchors too is a strictly larger change - it
    // would move every top/bottom-anchored label in every style - so it is left
    // as a follow-up rather than folded in here.
    {
        const auto top = inkExtent(shapeOneLine(style::SymbolAnchorType::Top, inkGlyph(11, 11)));
        const auto bottom = inkExtent(shapeOneLine(style::SymbolAnchorType::Bottom, inkGlyph(11, 11)));
        // shiftY = (-verticalAlign * lineCount + 0.5) * lineHeight, with the
        // baseline starting at Shaping::yOffset: top -> +12, bottom -> -12.
        near(top.first, -16.0, "top anchor unchanged by the patch");
        near(bottom.first, -40.0, "bottom anchor unchanged by the patch");
    }

    std::printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
