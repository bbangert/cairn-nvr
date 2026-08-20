defmodule CairnWeb.Components.Vision.Bbox do
  @moduledoc """
  Bounding-box overlays for a live video tile, ported from lawik's ex_nvr
  (`ui/lib/ex_nvr_web/components/vision/bbox.ex` on the `good-grid` branch),
  CSS included — see `assets/css/bbox.css`.

  Five visual styles:

    * `corner_brackets` — L-shaped corner marks over a faint fill
    * `dashed_glow` — dashed border with a pulsing glow
    * `svg_draw_in` — SVG polyline corners with a blinking centre dot
    * `gradient_border` — animated gradient border
    * `frosted_glass` — glassmorphism with backdrop blur

  `styles/0` and `style_label/1` enumerate them for a picker that does not
  exist yet: the default is hardwired at the call site
  (`CairnWeb.DashboardLive`) until a config key exposes the choice.

  Cairn's one delta from the port: `color` threads a hue into the `--c`
  custom property each style's CSS reads, so a caller can colour a box by
  what it found rather than by which style is on. `CairnWeb.DashboardLive`
  passes `CairnWeb.EventsLive.track_color/2` — the palette the playback
  overlay draws from, so a label looks like itself on both surfaces. Without
  `color` every style falls back to its own accent, as upstream.

  ## Assigns

    * `style_name` — which of `styles/0`
    * `label` / `confidence` — the tag's text
    * `color` — CSS color for `--c`, or `nil` for the style's own accent
    * `style` — the positioning CSS the caller computed
  """

  use Phoenix.Component

  @styles ~w(corner_brackets dashed_glow svg_draw_in gradient_border frosted_glass)a

  @spec styles() :: [atom()]
  def styles, do: @styles

  @spec style_label(atom()) :: String.t()
  def style_label(:corner_brackets), do: "Corner Brackets"
  def style_label(:dashed_glow), do: "Dashed Glow"
  def style_label(:svg_draw_in), do: "SVG Draw-In"
  def style_label(:gradient_border), do: "Gradient Border"
  def style_label(:frosted_glass), do: "Frosted Glass"

  attr :style_name, :atom, required: true
  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :color, :string, default: nil
  attr :style, :string, required: true

  def bbox(assigns) do
    assigns = assign(assigns, :style, assigns.style <> color_var(assigns.color))

    case assigns.style_name do
      :dashed_glow -> dashed_glow(assigns)
      :svg_draw_in -> svg_draw_in(assigns)
      :gradient_border -> gradient_border(assigns)
      :frosted_glass -> frosted_glass(assigns)
      # `corner_brackets` and anything unknown: an unrecognized style must
      # still draw a box, because a missing overlay reads as "nothing there".
      _ -> corner_brackets(assigns)
    end
  end

  defp color_var(nil), do: ""
  defp color_var(color), do: " --c: #{color};"

  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :style, :string, required: true

  def corner_brackets(assigns) do
    ~H"""
    <div class="bbox-corners" style={@style}>
      <div class="bbox-corners-fill"></div>
      <span class="bbox-corners-tr"></span>
      <span class="bbox-corners-bl"></span>
      <span class="bbox-corners-br"></span>
      <div class="bbox-corners-tag">{@label} · {@confidence}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :style, :string, required: true

  def dashed_glow(assigns) do
    ~H"""
    <div class="bbox-dashed" style={@style}>
      <div class="bbox-dashed-tag">{@label} · {@confidence}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :style, :string, required: true

  def svg_draw_in(assigns) do
    ~H"""
    <div class="bbox-svg-wrap" style={@style}>
      <%!-- preserveAspectRatio="none": added to the port. The viewBox is 5:3
      and a detection box is whatever shape the object is, so the default
      "meet" letterboxes the corner marks well inside a tall box. --%>
      <svg viewBox="0 0 200 120" preserveAspectRatio="none" class="bbox-svg-inner">
        <polyline class="bbox-svg-corner" points="0,20 0,0 20,0" />
        <polyline class="bbox-svg-corner" points="180,0 200,0 200,20" style="animation-delay:0.1s" />
        <polyline
          class="bbox-svg-corner"
          points="200,100 200,120 180,120"
          style="animation-delay:0.2s"
        />
        <polyline class="bbox-svg-corner" points="20,120 0,120 0,100" style="animation-delay:0.3s" />
        <circle class="bbox-svg-dot" cx="100" cy="60" r="3" />
      </svg>
      <div class="bbox-svg-tag">
        {@label} <span class="bbox-svg-conf">{@confidence}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :style, :string, required: true

  def gradient_border(assigns) do
    ~H"""
    <div class="bbox-gradient-wrap" style={@style}>
      <div class="bbox-gradient"></div>
      <div class="bbox-gradient-tag">{@label} · {@confidence}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :confidence, :string, default: ""
  attr :style, :string, required: true

  def frosted_glass(assigns) do
    ~H"""
    <div class="bbox-frost-wrap" style={@style}>
      <div class="bbox-frost"></div>
      <div class="bbox-frost-tag">
        <span class="bbox-frost-status"></span> {@label} · {@confidence}
      </div>
    </div>
    """
  end
end
