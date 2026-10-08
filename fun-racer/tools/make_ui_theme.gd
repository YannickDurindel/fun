extends SceneTree
## Regenerates assets/ui/theme.tres, the shared menu theme.
## Run: tools/bin/godot --headless --path . -s res://tools/make_ui_theme.gd
## Palette (also exposed as UIScreen.COL_*): dark navy panels, white text, blue accent, red highlight.

const BG := Color(0.03, 0.035, 0.05, 0.82)
const BG_HOVER := Color(0.10, 0.14, 0.24, 0.92)
const ACCENT := Color(0.16, 0.45, 1.0)
const HILITE := Color(0.93, 0.16, 0.16)
const TEXT := Color(1, 1, 1)
const TEXT_DIM := Color(1, 1, 1, 0.6)

func _box(bg: Color, border: Color, bw: int = 0, left_bar: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	if left_bar > 0:
		sb.border_width_left = left_bar
	sb.set_corner_radius_all(2)
	sb.skew = Vector2(0.12, 0.0)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

func _initialize() -> void:
	var bold: Font = load("res://assets/ui/fonts/BarlowCondensed-BoldItalic.ttf")
	var semi: Font = load("res://assets/ui/fonts/BarlowCondensed-SemiBoldItalic.ttf")
	var t := Theme.new()
	t.default_font = semi
	t.default_font_size = 26
	for type: String in ["Button", "OptionButton", "CheckButton", "CheckBox"]:
		t.set_font("font", type, bold)
		t.set_font_size("font_size", type, 30)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_focus_color", type, TEXT)
		t.set_color("font_pressed_color", type, TEXT)
		t.set_color("font_disabled_color", type, Color(1, 1, 1, 0.3))
		t.set_stylebox("normal", type, _box(BG, ACCENT, 0, 0))
		t.set_stylebox("hover", type, _box(BG_HOVER, ACCENT, 0, 6))
		t.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), HILITE, 0, 6))
		t.set_stylebox("pressed", type, _box(ACCENT.darkened(0.3), HILITE, 0, 6))
		t.set_stylebox("disabled", type, _box(Color(0.03, 0.035, 0.05, 0.45), ACCENT, 0, 0))
	t.set_font("font", "Label", semi)
	t.set_color("font_color", "Label", TEXT)
	t.set_type_variation("TitleLabel", "Label")
	t.set_font("font", "TitleLabel", bold)
	t.set_font_size("font_size", "TitleLabel", 72)
	t.set_type_variation("HeaderLabel", "Label")
	t.set_font("font", "HeaderLabel", bold)
	t.set_font_size("font_size", "HeaderLabel", 40)
	t.set_type_variation("DimLabel", "Label")
	t.set_color("font_color", "DimLabel", TEXT_DIM)
	t.set_font_size("font_size", "DimLabel", 22)
	var panel := _box(BG, ACCENT, 0, 0)
	panel.skew = Vector2.ZERO
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)
	var slider_bg := StyleBoxFlat.new()
	slider_bg.bg_color = Color(1, 1, 1, 0.18)
	slider_bg.content_margin_top = 4
	slider_bg.content_margin_bottom = 4
	var slider_fill := StyleBoxFlat.new()
	slider_fill.bg_color = ACCENT
	t.set_stylebox("slider", "HSlider", slider_bg)
	t.set_stylebox("grabber_area", "HSlider", slider_fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", slider_fill)
	t.set_font("font", "TabContainer", bold)
	t.set_font_size("font_size", "TabContainer", 28)
	var err := ResourceSaver.save(t, "res://assets/ui/theme.tres")
	print("theme saved: ", err)
	quit()
