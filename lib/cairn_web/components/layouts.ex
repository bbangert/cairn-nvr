defmodule CairnWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CairnWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  # The active nav item is the caller's to declare, not something derived from
  # the URL here: event detail lives under /events but is reached from either
  # browse page, and the one opened from a track row (`?track=` present) keeps
  # Tracks lit and offers "Back to tracks". So a LiveView may pass an assign
  # rather than a literal.
  attr :page, :atom,
    default: nil,
    doc: "which topbar nav item is active (:dashboard | :events | :tracks | :config)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div style="min-height: 100vh; display: flex; flex-direction: column; background: var(--hs-bg-canvas);">
      <header style="height: 56px; display: flex; align-items: center; gap: 8px; padding: 0 20px; background: var(--hs-bg-surface); border-bottom: 1px solid var(--hs-border-1); position: sticky; top: 0; z-index: 50; flex: none;">
        <div style="display: flex; align-items: center; gap: 9px; color: var(--hs-accent); margin-right: 16px;">
          <span class="ms" style="font-size: 24px;">terrain</span>
          <span style="font-size: 16px; font-weight: 700; letter-spacing: -0.01em; color: var(--hs-fg-1);">
            Cairn
          </span>
        </div>
        <nav style="display: flex; align-items: center; gap: 4px;">
          <.link navigate={~p"/"} class={["cairn-nav", @page == :dashboard && "cairn-nav--active"]}>
            <span class="ms" style="font-size: 19px;">videocam</span>Dashboard
          </.link>
          <.link navigate={~p"/events"} class={["cairn-nav", @page == :events && "cairn-nav--active"]}>
            <span class="ms" style="font-size: 19px;">video_library</span>Events
          </.link>
          <.link navigate={~p"/tracks"} class={["cairn-nav", @page == :tracks && "cairn-nav--active"]}>
            <span class="ms" style="font-size: 19px;">route</span>Tracks
          </.link>
          <.link navigate={~p"/config"} class={["cairn-nav", @page == :config && "cairn-nav--active"]}>
            <span class="ms" style="font-size: 19px;">tune</span>Config
          </.link>
        </nav>
        <div style="flex: 1;"></div>
        <span style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-4);">
          {host_readout()}
        </span>
      </header>

      {render_slot(@inner_block)}
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp host_readout do
    config = CairnWeb.Endpoint.config(:http) || []
    port = get_in(config, [:port]) || 4000
    "#{CairnWeb.Endpoint.host()}:#{port}"
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
