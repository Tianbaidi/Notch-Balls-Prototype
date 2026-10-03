# Notch Balls app icon · v2

浅色底板、简洁胶囊与双小球、蓝青渐变。根据对 v1 千禧风和强反光的反馈重做，收掉虹彩、厚边缘与硬件外壳。

`preview.png` 是使用内置 imagegen 编辑生成并由使用者选定的设计预览，含不透明浅灰背景。

`AppIcon.png` 是带标准透明圆角边界的 1024 × 1024 导出；`AppIcon.icns` 包含 16、32、128、256、512 点及对应 @2x 尺寸。运行 `./scripts/build-icon.sh` 可从已选预览重新导出，原图及内部造型不变。导出脚本使用原图坐标固定圆角边界，移除预览的外部底色与阴影。

从 0.41 起，`build.sh` 将 ICNS 写入 `Contents/Resources/AppIcon.icns`，`Info.plist` 通过 `CFBundleIconFile` 引用它。

## Design prompt

Use case: style-transfer.
Asset type: standalone macOS application icon, second design revision.
Edit the supplied icon for Notch Balls Prototype. The reference's concept is relevant, but its entire aesthetic must be redesigned: the user rejects its heavy rainbow chrome, blown glass ornament and Y2K skeuomorphic look.
Create ONE radically simplified, airy, contemporary native macOS icon. Preserve the conceptual identity of small balls expanding into useful horizontal capsules, but rebuild all rendering and composition.
A plain continuous-corner rounded-square tile occupies around 88% of the transparent square canvas. The tile is pearly off-white and subtly translucent, with extremely gentle cool gray shading, smooth and barely raised, NO hardware chassis, NO thick bezel, NO black background, NO carved notch in the perimeter. Thin quiet edge, almost flat frontal presentation.
The symbol centered inside is three SIMPLE clean shapes in a compact balanced composition: one wide blue horizontal capsule at mid-height and two smaller round dots just below it, cyan and muted periwinkle. The main capsule is smooth and uniform in thickness; no bulging fused orb, no bubble lobes. Keep the shapes bold, calm and readable at 32px. Main capsule spans approximately 60% of the tile width. The two dots are 11% of tile width each with elegant spacing.
Rendering: very restrained layered translucent color, satin-frosted clarity, clean silhouette and only a whisper of depth. Blue capsule with subtle ice-blue to cornflower gradient. No pink, no magenta, no rainbow edges. A soft, broad illumination across the upper surface, not a hard shiny specular stripe. No inflated glass, lenses, crystal, beads, bubbles or plastic toy appearance. The appearance should resemble a carefully built layered native app glyph, not a 3D product rendering. Tiny shadows only, no colored glow around shapes. Lots of unfilled negative space.
Do not copy an existing Apple app icon. No lettering, tiny UI glyphs, music notes, clock hands, grid, screenshots, logo watermarks or extra objects. Actual transparent pixels outside the rounded-square icon tile.

## Final preview prompt

Use case: precise-object-edit. Preserve the internal icon design in this supplied image: pearly white rounded-square tile, one simple blue horizontal capsule and two cyan/periwinkle circular dots, all positions, dimensions and smooth gradients. Make a pristine PRESENTATION PREVIEW on a completely opaque, uniform light neutral gray background (#ECEFF4), with the icon tile centered. Change only the exterior background and outer contour: rebuild the rounded square as a smooth precise clean shape, no stray flecks, brush marks, jagged edges, dust, holes or irregular outline. A VERY soft shallow neutral contact shadow is acceptable. No transparent pixels anywhere. No text, no frames or labels, no extra objects. Keep the interior minimalist and calm, as in the supplied design. Square canvas.
