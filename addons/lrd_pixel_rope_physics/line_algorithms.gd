@tool
## Pixel-perfect line drawing algorithms for rope rendering.
##
## Provides Bresenham's (integer-based, fast) and DDA (floating-point, smooth)
## algorithms for computing pixel positions along a line.
class_name LineAlgorithms
extends RefCounted

enum LineAlgorithmType {
	BRESENHAM, ## Integer-based, computationally efficient
	DDA        ## Floating-point based, visually smoother
}

## Longest single segment, in cells, that rasterize_path will walk. Longer jumps (a point that
## flew off to infinity) are drawn as their end cell only, so a bad frame can't hang the game.
const MAX_SEGMENT_CELLS := 4096


static func get_line_points(
	from_point: Vector2,
	to_point: Vector2,
	pixel_size: int,
	algorithm_type: LineAlgorithmType = LineAlgorithmType.BRESENHAM,
	pixel_spacing: int = 0
) -> Array[Vector2]:
	var grid_from := Vector2(
		round(from_point.x / pixel_size) * pixel_size,
		round(from_point.y / pixel_size) * pixel_size
	)
	var grid_to := Vector2(
		round(to_point.x / pixel_size) * pixel_size,
		round(to_point.y / pixel_size) * pixel_size
	)

	if algorithm_type == LineAlgorithmType.DDA:
		return _dda_line(grid_from, grid_to, pixel_size, pixel_spacing)
	return _bresenham_line(grid_from, grid_to, pixel_size, pixel_spacing)


static func _bresenham_line(from: Vector2, to: Vector2, pixel_size: int, spacing: int = 0) -> Array[Vector2]:
	var points: Array[Vector2] = []

	var x0 := int(from.x / pixel_size)
	var y0 := int(from.y / pixel_size)
	var x1 := int(to.x / pixel_size)
	var y1 := int(to.y / pixel_size)

	var dx := abs(x1 - x0)
	var dy: int = -abs(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err: int = dx + dy
	var pixel_count := 0

	while true:
		if spacing == 0 or pixel_count % (spacing + 1) == 0:
			points.append(Vector2(x0 * pixel_size, y0 * pixel_size))

		pixel_count += 1

		if x0 == x1 and y0 == y1:
			break

		var e2: int = 2 * err
		if e2 >= dy:
			if x0 == x1: break
			err += dy
			x0 += sx

		if e2 <= dx:
			if y0 == y1: break
			err += dx
			y0 += sy

	return points


## Rasterizes a whole polyline into one continuous path of grid cells.
##
## Points are snapped to a grid of [param pixel_size] in the space they are
## given in (pass global positions so the grid stays fixed in the world).
## Consecutive duplicate cells are dropped, so joints between segments are
## never emitted twice. When [param pixel_perfect] is true, L-shaped corners
## are removed (the same cleanup as Aseprite's "Pixel Perfect" freehand mode),
## leaving a clean 1-pixel stroke. Results are written into [param out]
## (cleared first) to avoid per-frame allocations.
static func rasterize_path(
	points: PackedVector2Array,
	pixel_size: int,
	algorithm_type: LineAlgorithmType,
	pixel_perfect: bool,
	out: PackedVector2Array
) -> void:
	out.clear()
	if points.is_empty():
		return

	var ps := float(maxi(pixel_size, 1))
	var start := 0
	while start < points.size() and not points[start].is_finite():
		start += 1
	if start == points.size():
		return
	var prev := Vector2i((points[start] / ps).floor())
	_push_cell(out, prev, pixel_perfect)

	for i in range(start + 1, points.size()):
		if not points[i].is_finite():
			continue
		var fcell := (points[i] / ps).floor()
		var cell := Vector2i(fcell)
		if cell == prev:
			continue
		# A runaway point must not stall the frame walking millions of cells. Measured in
		# floats because a huge coordinate overflows Vector2i.
		var span := (fcell - Vector2(prev)).abs()
		if maxf(span.x, span.y) > MAX_SEGMENT_CELLS:
			_push_cell(out, cell, pixel_perfect)
			prev = cell
			continue
		if algorithm_type == LineAlgorithmType.DDA:
			_walk_dda(prev, cell, out, pixel_perfect)
		else:
			_walk_bresenham(prev, cell, out, pixel_perfect)
		prev = cell


## Appends a cell, skipping duplicates and (optionally) removing L-corners.
## A corner is the middle of three cells where the outer two touch diagonally,
## e.g. (0,0) (1,0) (1,1): the (1,0) cell is redundant for an 8-connected line.
static func _push_cell(out: PackedVector2Array, cell: Vector2i, pixel_perfect: bool) -> void:
	var c := Vector2(cell)
	var n := out.size()
	if n > 0 and out[n - 1] == c:
		return
	if pixel_perfect and n >= 2:
		var a := out[n - 2]
		if absf(a.x - c.x) == 1.0 and absf(a.y - c.y) == 1.0:
			out[n - 1] = c
			return
		if a == c:
			# Path doubled back on itself: drop the spike.
			out.resize(n - 1)
			return
	out.append(c)


## Bresenham walk between two cells, excluding the start cell.
static func _walk_bresenham(from: Vector2i, to: Vector2i, out: PackedVector2Array, pixel_perfect: bool) -> void:
	var x0 := from.x
	var y0 := from.y
	var dx := absi(to.x - x0)
	var dy := -absi(to.y - y0)
	var sx := 1 if x0 < to.x else -1
	var sy := 1 if y0 < to.y else -1
	var err := dx + dy

	while x0 != to.x or y0 != to.y:
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
		_push_cell(out, Vector2i(x0, y0), pixel_perfect)


## DDA walk between two cells, excluding the start cell.
static func _walk_dda(from: Vector2i, to: Vector2i, out: PackedVector2Array, pixel_perfect: bool) -> void:
	var d := Vector2(to - from)
	var steps := int(maxf(absf(d.x), absf(d.y)))
	var inc := d / float(steps)
	var p := Vector2(from)
	for _i in steps:
		p += inc
		_push_cell(out, Vector2i(p.round()), pixel_perfect)


static func _dda_line(from: Vector2, to: Vector2, pixel_size: int, spacing: int = 0) -> Array[Vector2]:
	var points: Array[Vector2] = []

	var x0 := from.x / pixel_size
	var y0 := from.y / pixel_size
	var x1 := to.x / pixel_size
	var y1 := to.y / pixel_size

	var dx := x1 - x0
	var dy := y1 - y0
	var steps := max(abs(dx), abs(dy))

	if steps < 1:
		points.append(Vector2(round(x0) * pixel_size, round(y0) * pixel_size))
		return points

	var x_inc: float = dx / steps
	var y_inc: float = dy / steps
	var x := x0
	var y := y0

	for i in range(int(steps) + 1):
		if spacing == 0 or i % (spacing + 1) == 0:
			points.append(Vector2(round(x) * pixel_size, round(y) * pixel_size))
		x += x_inc
		y += y_inc

	return points
