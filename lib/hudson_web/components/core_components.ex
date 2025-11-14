defmodule HudsonWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The styling follows a semantic CSS architecture using ITCSS (Inverted Triangle CSS)
  with BEM naming conventions. CSS is organized into modular files in `assets/css/`
  and bundled by esbuild. Here are useful references:

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: HudsonWeb.Gettext

  alias Phoenix.HTML.{Form, FormField}
  alias Phoenix.LiveView.JS

  # Verified routes for navigation
  use Phoenix.VerifiedRoutes,
    endpoint: HudsonWeb.Endpoint,
    router: HudsonWeb.Router,
    statics: HudsonWeb.static_paths()

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast--top-end"
      {@rest}
    >
      <div class={[
        "alert",
        @kind == :info && "alert--info",
        @kind == :error && "alert--error"
      ]}>
        <div class="alert__icon">
          <.icon :if={@kind == :info} name="hero-information-circle" class="size-5" />
          <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5" />
        </div>
        <div class="alert__content">
          <p :if={@title} class="alert__title">{@title}</p>
          <p class="alert__message">{msg}</p>
        </div>
        <button type="button" class="alert__close" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
      <.button variant="outline-error" size="sm">Delete</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :string, default: nil
  attr :variant, :string, default: nil
  attr :size, :string, default: nil
  attr :circle, :boolean, default: false
  attr :square, :boolean, default: false
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # Build class list from attributes
    classes =
      ["button"]
      |> add_variant_class(assigns[:variant])
      |> add_size_class(assigns[:size])
      |> add_shape_classes(assigns[:circle], assigns[:square])
      |> add_custom_class(assigns[:class])

    assigns = assign(assigns, :computed_class, Enum.join(classes, " "))

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@computed_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset">
      <label>
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset">
      <label>
        <span :if={@label} class="label">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "select", @errors != [] && (@error_class || "select--error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset">
      <label>
        <span :if={@label} class="label">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "textarea",
            @errors != [] && (@error_class || "textarea--error")
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset">
      <label>
        <span :if={@label} class="label">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={[
            @class || "input",
            @errors != [] && (@error_class || "input--error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="error-message">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="stack stack--sm">
      <div class={[@actions != [] && "flex flex--between flex--center"]}>
        <div class="stack stack--xs">
          <h1 class="text-3xl font-bold">
            {render_slot(@inner_block)}
          </h1>
          <p :if={@subtitle != []} class="text-secondary">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []}>{render_slot(@actions)}</div>
      </div>
    </header>
    """
  end

  @doc """
  Renders a navigation bar with tabs and page-specific action buttons.

  ## Examples

      <.nav_tabs current_page={:sessions} />
      <.nav_tabs current_page={:products} />
  """
  attr :current_page, :atom, required: true

  def nav_tabs(assigns) do
    ~H"""
    <nav class="navbar">
      <div class="navbar__nav">
        <.link
          href={~p"/sessions"}
          class={["navbar__link", @current_page == :sessions && "navbar__link--active"]}
        >
          Sessions
        </.link>
        <.link
          href={~p"/products"}
          class={["navbar__link", @current_page == :products && "navbar__link--active"]}
        >
          Products
        </.link>
      </div>
      <div class="navbar__end">
        <.button :if={@current_page == :sessions} phx-click="show_new_session_modal" variant="primary">
          New Session
        </.button>
      </div>
    </nav>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a modal dialog.

  ## Usage Pattern

  **Always use conditional rendering** around the modal component. The modal will automatically
  show when mounted (via `phx-mounted`) and hide when unmounted.

  ### Example 1: Simple Modal

      <!-- In your template -->
      <%= if @show_new_session_modal do %>
        <.modal id="new-session-modal" show={true} on_cancel={JS.push("close_modal")}>
          <div class="modal__header">
            <h2 class="modal__title">New Session</h2>
          </div>
          <div class="modal__body">
            <.form for={@form} phx-submit="save">
              <!-- form fields -->
            </.form>
          </div>
        </.modal>
      <% end %>

      <!-- Trigger button -->
      <.button phx-click="show_new_session_modal">New Session</.button>

      # In your LiveView:
      def handle_event("show_new_session_modal", _params, socket) do
        {:noreply, assign(socket, :show_new_session_modal, true)}
      end

      def handle_event("close_modal", _params, socket) do
        {:noreply, assign(socket, :show_new_session_modal, false)}
      end

  ### Example 2: Modal with Server Data Loading

      <!-- In your template -->
      <%= if @selected_product do %>
        <.modal id="edit-product-modal" show={true} on_cancel={JS.push("close_product_modal")}>
          <div class="modal__header">
            <h2 class="modal__title">Edit Product</h2>
          </div>
          <div class="modal__body">
            <.form for={@product_form} phx-submit="save_product">
              <!-- form fields using @selected_product -->
            </.form>
          </div>
        </.modal>
      <% end %>

      <!-- Trigger button -->
      <.button phx-click="load_product" phx-value-id={product.id}>Edit</.button>

      # In your LiveView:
      def handle_event("load_product", %{"id" => id}, socket) do
        product = Products.get_product!(id)
        {:noreply, assign(socket, :selected_product, product)}
      end

      def handle_event("close_product_modal", _params, socket) do
        {:noreply, assign(socket, :selected_product, nil)}
      end

  ## Important Notes

  - **Always wrap modals in conditional rendering** (`<%= if @condition do %>`)
  - Set `show={true}` on the modal component
  - The modal auto-shows when the condition becomes true (component mounts)
  - The modal auto-hides when the condition becomes false (component unmounts)
  - The `on_cancel` attribute handles cleanup when modal closes via backdrop, Escape, or X button
  - Form validation events (like dropdowns) work correctly with this pattern
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :modal_class, :string, default: "", doc: "Additional CSS classes for the modal box"
  attr :rest, :global, doc: "arbitrary HTML attributes to add to the modal container"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="modal modal--hidden"
      {@rest}
    >
      <div id={"#{@id}-bg"} class="modal__backdrop" aria-hidden="true" />
      <div
        class="modal__container"
        aria-labelledby={"#{@id}-title"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="modal__centering">
          <.focus_wrap
            id={"#{@id}-container"}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            class={["modal__box", @modal_class]}
          >
            <button
              type="button"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              class="modal__close"
              aria-label={gettext("close")}
            >
              ✕
            </button>
            {render_slot(@inner_block)}
          </.focus_wrap>
        </div>
      </div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector, time: 300)
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector, time: 200)
  end

  @doc """
  Shows a modal dialog.
  """
  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.remove_class("modal--hidden", to: "##{id}")
    |> JS.add_class("overflow-hidden", to: "html")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-container")
  end

  @doc """
  Hides a modal dialog.
  """
  def hide_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.add_class("modal--hidden", to: "##{id}")
    |> JS.remove_class("overflow-hidden", to: "html")
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(HudsonWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(HudsonWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  # Button helper functions

  @button_variants %{
    "primary" => "button--primary",
    "success" => "button--success",
    "warning" => "button--warning",
    "error" => "button--error",
    "ghost" => "button--ghost",
    "outline" => "button--outline",
    "outline-error" => "button--outline-error"
  }

  @button_sizes %{
    "xs" => "button--xs",
    "sm" => "button--sm",
    "lg" => "button--lg"
  }

  defp add_variant_class(classes, variant) when is_binary(variant) do
    case Map.get(@button_variants, variant) do
      nil -> classes
      class -> classes ++ [class]
    end
  end

  defp add_variant_class(classes, _), do: classes

  defp add_size_class(classes, size) when is_binary(size) do
    case Map.get(@button_sizes, size) do
      nil -> classes
      class -> classes ++ [class]
    end
  end

  defp add_size_class(classes, _), do: classes

  defp add_shape_classes(classes, circle, square) do
    classes
    |> maybe_add_class(circle, "button--circle")
    |> maybe_add_class(square, "button--square")
  end

  defp add_custom_class(classes, nil), do: classes
  defp add_custom_class(classes, custom_class), do: classes ++ [custom_class]

  defp maybe_add_class(classes, true, class_name), do: classes ++ [class_name]
  defp maybe_add_class(classes, _, _), do: classes

  @doc """
  Formats a NaiveDateTime into a human-friendly relative time string.

  ## Examples

      iex> format_relative_time(~N[2025-01-14 12:00:00])
      "2 hours ago"

      iex> format_relative_time(~N[2025-01-13 12:00:00])
      "Yesterday"

      iex> format_relative_time(~N[2025-01-07 12:00:00])
      "7 days ago"
  """
  def format_relative_time(nil), do: "Never"

  def format_relative_time(%NaiveDateTime{} = datetime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        "Just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes} #{pluralize("minute", minutes)} ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} #{pluralize("hour", hours)} ago"

      diff_seconds < 172_800 ->
        "Yesterday"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86400)
        "#{days} days ago"

      diff_seconds < 2_592_000 ->
        weeks = div(diff_seconds, 604_800)
        "#{weeks} #{pluralize("week", weeks)} ago"

      diff_seconds < 31_536_000 ->
        months = div(diff_seconds, 2_592_000)
        "#{months} #{pluralize("month", months)} ago"

      true ->
        years = div(diff_seconds, 31_536_000)
        "#{years} #{pluralize("year", years)} ago"
    end
  end

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: "#{word}s"
end
