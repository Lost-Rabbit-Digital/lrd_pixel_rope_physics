@tool
extends EditorPlugin
## Registers the [code]PixelRope[/code] and [code]RopeAnchor[/code] node types and adds the
## rope creation button to the 2D editor toolbar while the plugin is enabled.

const PixelRopeScript := preload("res://addons/lrd_pixel_rope_physics/pixel_rope.gd")
const RopeAnchorScript := preload("res://addons/lrd_pixel_rope_physics/rope_anchor.gd")
const RopeCreationTool := preload("res://addons/lrd_pixel_rope_physics/rope_creation_tool.gd")
const ROPE_ICON := preload("res://addons/lrd_pixel_rope_physics/icons/Curve2D.svg")
const ANCHOR_ICON := preload("res://addons/lrd_pixel_rope_physics/icons/CircleShape2D.svg")

var _creation_tool: RopeCreationTool


func _enter_tree() -> void:
	add_custom_type("PixelRope", "Node2D", PixelRopeScript, ROPE_ICON)
	add_custom_type("RopeAnchor", "Node2D", RopeAnchorScript, ANCHOR_ICON)

	_creation_tool = RopeCreationTool.new()
	_creation_tool.initialize(self)
	# The creation tool places ropes wherever the user clicks, so it needs canvas input even when
	# nothing the plugin handles is selected.
	set_input_event_forwarding_always_enabled()

	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)


func _exit_tree() -> void:
	remove_custom_type("PixelRope")
	remove_custom_type("RopeAnchor")

	var selection := EditorInterface.get_selection()
	if selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.disconnect(_on_selection_changed)

	if _creation_tool:
		_creation_tool.cleanup()
		_creation_tool = null


func _handles(object: Object) -> bool:
	return object is PixelRope or object is RopeAnchor


func _forward_canvas_gui_input(event: InputEvent) -> bool:
	return _creation_tool != null and _creation_tool.handle_input(event)


## Redraws the selected rope (or the rope that owns the selected anchor) so its editor preview
## follows the selection.
func _on_selection_changed() -> void:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	if selected.size() != 1:
		return

	var node: Node = selected[0]
	if node is RopeAnchor:
		node = node.get_parent()
	if node is PixelRope:
		node.queue_redraw()
