package skinpack

import (
	"fmt"
	"image/color"
	"maps"
	"slices"

	"befriend/pkg/utils/vocabulary"
)

// FaceLayerName is the layer whose opacity an app sets to show a mood (keypath "face_<mood>.Transform.Opacity").
func FaceLayerName(mood string) string {
	return "face_" + mood
}

// lottie builds the animation: a marker per action in vocabulary order then per motion, one shape layer per
// timeline frame, and a face layer per mood on top. Faces follow each frame's '@' with hold keyframes and scale to
// nothing on frames without one. Only the content face is opaque in the file, so previews show a face; apps set all
// twelve.
func (s *source) lottie() map[string]any {
	var markers []any
	var bodyLayers []map[string]any
	var positions, scales [][]int
	frame := 0
	for _, c := range s.meta.timeline() {
		markers = append(markers, map[string]any{"cm": c.name, "tm": frame, "dr": len(c.frames)})
		for i, name := range c.frames {
			body := s.bodies[name]
			bodyLayers = append(bodyLayers, s.shapeLayer(fmt.Sprintf("%s %d", c.name, i), body, frame, frame+1))
			if body.faceX >= 0 {
				positions = append(positions, []int{body.faceX, body.faceY, 0})
				scales = append(scales, []int{100, 100, 100})
			} else {
				positions = append(positions, lastOr(positions, []int{0, 0, 0}))
				scales = append(scales, []int{0, 0, 100})
			}
			frame++
		}
		// lottie-ios plays a marker through tm+dr inclusive, so the last pose also covers that frame; otherwise a
		// one-shot would settle on the next action's first frame.
		bodyLayers[len(bodyLayers)-1]["op"] = frame + 1
		positions = append(positions, lastOr(positions, nil))
		scales = append(scales, lastOr(scales, nil))
		frame++
	}

	// Faces are plain shape layers moved by their transform: no precomps, which renderers handle less reliably.
	var layers []any
	for _, mood := range vocabulary.Moods {
		opacity := 0
		if mood == "content" {
			opacity = 100
		}
		face := s.shapeLayer(FaceLayerName(mood), s.faces[mood], 0, frame)
		face["ind"] = len(layers) + 1
		face["ks"] = transform(held(positions), held(scales), static(opacity))
		layers = append(layers, face)
	}
	for _, layer := range bodyLayers {
		layer["ind"] = len(layers) + 1
		layers = append(layers, layer)
	}

	return map[string]any{
		"v": "5.7.4", "nm": s.meta.Name, "fr": s.meta.FPS, "ip": 0, "op": frame, "w": Size, "h": Size, "ddd": 0,
		"assets": []any{}, "layers": layers, "markers": markers,
	}
}

// shapeLayer draws a grid as a shape layer: one group per palette colour holding merged rectangles.
func (s *source) shapeLayer(name string, g *grid, ip, op int) map[string]any {
	byColor := map[byte][]any{}
	for _, r := range rects(g) {
		byColor[r.c] = append(byColor[r.c], map[string]any{
			"ty": "rc", "nm": "px", "d": 1, "r": static(0),
			"p": static([]float64{float64(r.x) + float64(r.w)/2, float64(r.y) + float64(r.h)/2}),
			"s": static([]int{r.w, r.h}),
		})
	}
	var groups []any
	for _, c := range slices.Sorted(maps.Keys(byColor)) {
		items := append(byColor[c], fill(s.palette[c]), groupTransform())
		groups = append(groups, map[string]any{"ty": "gr", "nm": string(c), "it": items})
	}
	return map[string]any{
		"ddd": 0, "ty": 4, "nm": name, "sr": 1, "ao": 0, "bm": 0, "ip": ip, "op": op, "st": 0,
		"ks":     transform(static([]int{0, 0, 0}), static([]int{100, 100, 100}), static(100)),
		"shapes": groups,
	}
}

type rect struct {
	x, y, w, h int
	c          byte
}

// rects covers a grid's opaque cells with rectangles: a run along a row, grown downward while the rows below
// repeat it. Fewer shapes render faster and leave no seams inside a run.
func rects(g *grid) []rect {
	used := make([]bool, len(g.cells))
	free := func(x, y int, c byte) bool {
		i := y*g.w + x
		return g.cells[i] == c && !used[i]
	}
	runFree := func(x, y, w int, c byte) bool {
		for dx := 0; dx < w; dx++ {
			if !free(x+dx, y, c) {
				return false
			}
		}
		return true
	}

	var out []rect
	for y := 0; y < g.h; y++ {
		for x := 0; x < g.w; x++ {
			c := g.cells[y*g.w+x]
			if c == transparent || !free(x, y, c) {
				continue
			}
			w := 1
			for x+w < g.w && free(x+w, y, c) {
				w++
			}
			h := 1
			for y+h < g.h && runFree(x, y+h, w, c) {
				h++
			}
			for dy := 0; dy < h; dy++ {
				for dx := 0; dx < w; dx++ {
					used[(y+dy)*g.w+x+dx] = true
				}
			}
			out = append(out, rect{x, y, w, h, c})
			x += w - 1
		}
	}
	return out
}

func static(v any) map[string]any {
	return map[string]any{"a": 0, "k": v}
}

// held animates a value that jumps between frames (hold keyframes), or stays static when it never changes.
func held(values [][]int) map[string]any {
	var keys []any
	for t, v := range values {
		if t == 0 || !slices.Equal(v, values[t-1]) {
			keys = append(keys, map[string]any{"t": t, "s": v, "h": 1})
		}
	}
	if len(keys) == 1 {
		return static(values[0])
	}
	return map[string]any{"a": 1, "k": keys}
}

func transform(position, scale, opacity map[string]any) map[string]any {
	return map[string]any{"a": static([]int{0, 0, 0}), "p": position, "s": scale, "r": static(0), "o": opacity}
}

func fill(c color.NRGBA) map[string]any {
	return map[string]any{"ty": "fl", "nm": "fill", "r": 1, "o": static(100),
		"c": static([]float64{float64(c.R) / 255, float64(c.G) / 255, float64(c.B) / 255, 1})}
}

func groupTransform() map[string]any {
	return map[string]any{"ty": "tr", "nm": "transform", "p": static([]int{0, 0}), "a": static([]int{0, 0}),
		"s": static([]int{100, 100}), "r": static(0), "o": static(100), "sk": static(0), "sa": static(0)}
}

func lastOr(values [][]int, fallback []int) []int {
	if len(values) == 0 {
		return fallback
	}
	return values[len(values)-1]
}
