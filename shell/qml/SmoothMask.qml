import QtQuick
import QtQuick.Effects

// A MultiEffect that cuts its source to a mask and keeps the mask's antialiased edge (T-314, 04 §5.2).
// Every rounded mask in the shell goes through it: the picture of AppArt and of the wallpaper tiles,
// the card glare, the glass blur of pills and sheets, and the cut-out of GlassShadow.
//
// MultiEffect's default mask thresholds (`maskThresholdMin` 0, `maskSpreadAtMin` 0) make every pixel
// the mask touches at all fully opaque: the smooth edge of a rounded Rectangle becomes hard
// stair-steps that lie up to a pixel outside the outline, so the picture pokes out past the
// hairline, the ring and the caption fade that are drawn with the same radius. A threshold of 0.5
// with a spread of 1 maps the mask's coverage 0..1 through a smoothstep: the 50 % point stays on the
// outline and the edge keeps its one-pixel ramp. Same pass, same textures: no extra cost.
//
// `maskSource` is a hidden Rectangle with `layer.enabled` and `layer.smooth: true` (a scaled card
// samples it between texels; nearest sampling would bring the steps back).
MultiEffect {
    maskEnabled: true
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
    autoPaddingEnabled: false
}
