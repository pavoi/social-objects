defmodule SocialObjectsWeb.CoreComponents do
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
  use Gettext, backend: SocialObjectsWeb.Gettext

  alias SocialObjectsWeb.BrandRoutes
  alias Phoenix.HTML.{Form, FormField}
  alias Phoenix.LiveView.JS

  # Verified routes for navigation
  use Phoenix.VerifiedRoutes,
    endpoint: SocialObjectsWeb.Endpoint,
    router: SocialObjectsWeb.Router,
    statics: SocialObjectsWeb.static_paths()

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
          <svg
            :if={@kind == :info}
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="size-5"
          >
            <path
              fill-rule="evenodd"
              d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12zm8.706-1.442c1.146-.573 2.437.463 2.126 1.706l-.709 2.836.042-.02a.75.75 0 01.67 1.34l-.04.022c-1.147.573-2.438-.463-2.127-1.706l.71-2.836-.042.02a.75.75 0 11-.671-1.34l.041-.022zM12 9a.75.75 0 100-1.5.75.75 0 000 1.5z"
              clip-rule="evenodd"
            />
          </svg>
          <svg
            :if={@kind == :error}
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="size-5"
          >
            <path
              fill-rule="evenodd"
              d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12zM12 8.25a.75.75 0 01.75.75v3.75a.75.75 0 01-1.5 0V9a.75.75 0 01.75-.75zm0 8.25a.75.75 0 100-1.5.75.75 0 000 1.5z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <div class="alert__content">
          <p :if={@title} class="alert__title">{@title}</p>
          <p class="alert__message">{msg}</p>
        </div>
        <button type="button" class="alert__close" aria-label={gettext("close")}>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="currentColor"
            class="size-5"
          >
            <path
              fill-rule="evenodd"
              d="M5.47 5.47a.75.75 0 011.06 0L12 10.94l5.47-5.47a.75.75 0 111.06 1.06L13.06 12l5.47 5.47a.75.75 0 11-1.06 1.06L12 13.06l-5.47 5.47a.75.75 0 01-1.06-1.06L10.94 12 5.47 6.53a.75.75 0 010-1.06z"
              clip-rule="evenodd"
            />
          </svg>
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
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
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
      <svg
        class="size-5"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <circle cx="12" cy="12" r="10" />
        <line x1="12" y1="8" x2="12" y2="12" />
        <line x1="12" y1="16" x2="12.01" y2="16" />
      </svg>
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a secret/password input with visibility toggle and configured indicator.

  Shows a "Configured" badge when the field has a value set.
  Allows toggling between masked and visible modes.

  ## Examples

      <.secret_input
        field={@form[:api_key]}
        key="api_key"
        label="API Key"
        placeholder="sk-..."
        configured={true}
        visible={false}
      />
  """
  attr :field, FormField, required: true
  attr :key, :string, required: true, doc: "Unique key for this secret field"
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :configured, :boolean, default: false
  attr :visible, :boolean, default: false
  attr :multiline, :boolean, default: false
  attr :rest, :global

  def secret_input(assigns) do
    assigns =
      assigns
      |> assign(:name, assigns.field.name)
      |> assign(:id, assigns.field.id)
      |> assign(:value, assigns.field.value)

    ~H"""
    <div class="fieldset">
      <div class="secret-field__header">
        <span class="label">{@label}</span>
        <span :if={@configured} class="secret-field__badge">Configured</span>
      </div>
      <div class="secret-field__input-wrapper">
        <%= if @multiline do %>
          <textarea
            id={@id}
            name={@name}
            placeholder={@placeholder}
            class="textarea secret-field__textarea"
            {@rest}
          >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
        <% else %>
          <input
            type={if @visible, do: "text", else: "password"}
            id={@id}
            name={@name}
            value={@value}
            placeholder={@placeholder}
            class="input secret-field__input"
            {@rest}
          />
        <% end %>
        <button
          type="button"
          class="secret-field__toggle"
          phx-click="toggle_secret_visibility"
          phx-value-key={@key}
          title={if @visible, do: "Hide", else: "Show"}
        >
          <.icon :if={!@visible} name="hero-eye" class="size-4" />
          <.icon :if={@visible} name="hero-eye-slash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a search input with an optional clear button.

  The clear button appears on the right side of the input when text is entered.

  ## Attributes
  - `name` - The input name (default: "value")
  - `value` - The current search value
  - `placeholder` - Placeholder text (default: "Search...")
  - `on_change` - Event name to trigger on input change (required)
  - `on_submit` - Event name to trigger on form submit (default: same as on_change)
  - `on_clear` - Event name to trigger when clear button is clicked (default: same as on_change)
  - `debounce` - Debounce delay in milliseconds (default: 300)
  - `class` - Additional CSS classes for the input

  ## Examples

      <.search_input
        value={@search_query}
        on_change="search"
        placeholder="Search products..."
      />
  """
  attr :name, :string, default: "value"
  attr :value, :string, required: true
  attr :placeholder, :string, default: "Search..."
  attr :on_change, :string, required: true
  attr :on_submit, :string, default: nil
  attr :on_clear, :string, default: nil
  attr :debounce, :integer, default: 300
  attr :class, :string, default: nil

  def search_input(assigns) do
    # Set defaults for optional events - use on_change if not explicitly set
    # Use a stable ID based on the event name, not the full assigns
    assigns =
      assigns
      |> assign(:on_submit, assigns[:on_submit] || assigns.on_change)
      |> assign(:on_clear, assigns[:on_clear] || assigns.on_change)
      |> assign_new(:input_id, fn -> "search-input-#{assigns.on_change}" end)

    ~H"""
    <div class="search-input">
      <form phx-change={@on_change} phx-submit={@on_submit}>
        <input
          id={@input_id}
          type="text"
          name={@name}
          placeholder={@placeholder}
          value={@value}
          phx-debounce={@debounce}
          class={["input input--sm search-input__field", @class]}
        />
        <%= if @value != "" do %>
          <button
            type="button"
            class="search-input__clear"
            phx-click={
              if @on_clear do
                JS.push(@on_clear, value: %{@name => ""})
                |> JS.set_attribute({"value", ""}, to: "##{@input_id}")
              else
                JS.set_attribute({"value", ""}, to: "##{@input_id}")
                |> JS.dispatch("input", to: "##{@input_id}")
              end
            }
            aria-label="Clear search"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 20 20"
              fill="currentColor"
              style="width: 16px; height: 16px;"
            >
              <path d="M6.28 5.22a.75.75 0 00-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 101.06 1.06L10 11.06l3.72 3.72a.75.75 0 101.06-1.06L11.06 10l3.72-3.72a.75.75 0 00-1.06-1.06L10 8.94 6.28 5.22z" />
            </svg>
          </button>
        <% end %>
      </form>
    </div>
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
    <header class="flex flex-col gap-2">
      <div class={[@actions != [] && "flex flex--between flex--center"]}>
        <div class="flex flex-col gap-1">
          <h1 class="text-3xl font-bold">
            {render_slot(@inner_block)}
          </h1>
          <p :if={@subtitle != []} class="text-text-secondary">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []}>{render_slot(@actions)}</div>
      </div>
    </header>
    """
  end

  @doc """
  Renders a brand logo with fallback to brand name initial.

  ## Examples

      <.brand_logo brand={@brand} size="sm" />
      <.brand_logo brand={@brand} size="md" />
  """
  attr :brand, :map, required: true
  attr :size, :string, default: "sm", values: ["sm", "md"]

  def brand_logo(assigns) do
    ~H"""
    <div class={["brand-logo", "brand-logo--#{@size}"]}>
      <%= if @brand.logo_url do %>
        <img src={@brand.logo_url} alt={@brand.name} class="brand-logo__img" />
      <% else %>
        <span class="brand-logo__fallback">
          {String.first(@brand.name)}
        </span>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a navigation bar with tabs and page-specific action buttons.

  ## Examples

      <.nav_tabs current_page={:products} />
  """
  attr :current_page, :atom, required: true
  attr :current_scope, :map, required: true
  attr :current_brand, :map, default: nil
  attr :user_brands, :list, default: []
  attr :current_host, :string, default: nil
  attr :is_admin, :boolean, default: false
  attr :feature_flags, :map, default: %{}

  def nav_tabs(assigns) do
    ~H"""
    <nav id="global-nav" class="navbar">
      <div class="navbar__start">
        <div class="navbar__brand-switcher">
          <%= if length(@user_brands) > 1 do %>
            <button
              type="button"
              class="brand-switcher__toggle"
              aria-haspopup="true"
              aria-label="Switch brand"
              phx-click={
                JS.toggle(to: "#brand-switcher-menu", in: "fade-in", out: "fade-out", display: "flex")
              }
            >
              <.brand_logo brand={@current_brand} size="sm" />
              <svg
                class="size-4"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="m19.5 8.25-7.5 7.5-7.5-7.5" />
              </svg>
            </button>
            <div
              id="brand-switcher-menu"
              class="brand-switcher__menu"
              phx-click-away={JS.hide(to: "#brand-switcher-menu", transition: "fade-out")}
            >
              <.link
                :for={user_brand <- @user_brands}
                navigate={nav_path(@current_page, user_brand.brand, nil)}
                class={[
                  "brand-switcher__item",
                  user_brand.brand.id == @current_brand.id && "brand-switcher__item--active"
                ]}
              >
                <.brand_logo brand={user_brand.brand} size="sm" />
                <span class="brand-switcher__item-name">{user_brand.brand.name}</span>
                <.icon
                  :if={user_brand.brand.id == @current_brand.id}
                  name="hero-check"
                  class="size-4"
                />
              </.link>
            </div>
          <% else %>
            <div class="brand-switcher__single">
              <.brand_logo brand={@current_brand} size="sm" />
            </div>
          <% end %>
        </div>
      </div>

      <div class="navbar__nav" data-nav-links>
        <.link
          navigate={nav_path(:products, @current_brand, @current_host)}
          class={["navbar__link", @current_page == :products && "navbar__link--active"]}
          data-nav-link
        >
          Products
        </.link>
        <.link
          navigate={nav_path(:streams, @current_brand, @current_host)}
          class={["navbar__link", @current_page == :streams && "navbar__link--active"]}
          data-nav-link
        >
          Streams
        </.link>
        <.link
          navigate={nav_path(:creators, @current_brand, @current_host)}
          class={["navbar__link", @current_page == :creators && "navbar__link--active"]}
          data-nav-link
        >
          Creators
        </.link>
        <%= if Map.get(@feature_flags, "show_videos_nav", true) do %>
          <.link
            navigate={nav_path(:videos, @current_brand, @current_host)}
            class={["navbar__link", @current_page == :videos && "navbar__link--active"]}
            data-nav-link
          >
            Videos
          </.link>
        <% end %>
        <%= if Map.get(@feature_flags, "show_analytics_nav", true) do %>
          <.link
            navigate={nav_path(:shop_analytics, @current_brand, @current_host)}
            class={["navbar__link", @current_page == :shop_analytics && "navbar__link--active"]}
            data-nav-link
          >
            Analytics
          </.link>
        <% end %>
        <.link
          :if={@is_admin}
          navigate={~p"/admin"}
          class={["navbar__link", @current_page == :admin && "navbar__link--active"]}
          data-nav-link
        >
          Admin
        </.link>
      </div>

      <div class="navbar__end">
        <div class="navbar__nav-dropdown">
          <button
            type="button"
            class="navbar__nav-dropdown-trigger"
            aria-haspopup="true"
            aria-label="Navigation menu"
            phx-click={
              JS.toggle(to: "#nav-dropdown-menu", in: "fade-in", out: "fade-out", display: "flex")
            }
          >
            <span class="navbar__nav-dropdown-label">{nav_label(@current_page)}</span>
            <svg
              class="size-4"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="m19.5 8.25-7.5 7.5-7.5-7.5" />
            </svg>
          </button>
          <div
            id="nav-dropdown-menu"
            class="navbar__nav-dropdown-menu"
            phx-click-away={JS.hide(to: "#nav-dropdown-menu", transition: "fade-out")}
          >
            <.link
              navigate={nav_path(:products, @current_brand, @current_host)}
              class={[
                "navbar__nav-dropdown-item",
                @current_page == :products && "navbar__nav-dropdown-item--active"
              ]}
            >
              Products
            </.link>
            <.link
              navigate={nav_path(:streams, @current_brand, @current_host)}
              class={[
                "navbar__nav-dropdown-item",
                @current_page == :streams && "navbar__nav-dropdown-item--active"
              ]}
            >
              Streams
            </.link>
            <.link
              navigate={nav_path(:creators, @current_brand, @current_host)}
              class={[
                "navbar__nav-dropdown-item",
                @current_page == :creators && "navbar__nav-dropdown-item--active"
              ]}
            >
              Creators
            </.link>
            <%= if Map.get(@feature_flags, "show_videos_nav", true) do %>
              <.link
                navigate={nav_path(:videos, @current_brand, @current_host)}
                class={[
                  "navbar__nav-dropdown-item",
                  @current_page == :videos && "navbar__nav-dropdown-item--active"
                ]}
              >
                Videos
              </.link>
            <% end %>
            <%= if Map.get(@feature_flags, "show_analytics_nav", true) do %>
              <.link
                navigate={nav_path(:shop_analytics, @current_brand, @current_host)}
                class={[
                  "navbar__nav-dropdown-item",
                  @current_page == :shop_analytics && "navbar__nav-dropdown-item--active"
                ]}
              >
                Analytics
              </.link>
            <% end %>
            <.link
              :if={@is_admin}
              navigate={~p"/admin"}
              class={[
                "navbar__nav-dropdown-item",
                @current_page == :admin && "navbar__nav-dropdown-item--active"
              ]}
            >
              Admin
            </.link>
          </div>
        </div>
        <.link
          navigate={~p"/users/settings"}
          class="navbar__settings-link"
          aria-label="Account settings"
        >
          <svg
            class="size-5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </.link>
      </div>
    </nav>
    """
  end

  defp nav_path(page, brand, current_host) do
    BrandRoutes.brand_path(brand, nav_page_path(page), current_host)
  end

  defp nav_page_path(:products), do: "/products"
  defp nav_page_path(:streams), do: "/streams"
  defp nav_page_path(:creators), do: "/creators"
  defp nav_page_path(:videos), do: "/videos"
  defp nav_page_path(:shop_analytics), do: "/shop-analytics"
  defp nav_page_path(:readme), do: "/readme"
  # Non-brand-scoped pages default to products when switching brands
  defp nav_page_path(_), do: "/products"

  defp nav_label(:products), do: "Products"
  defp nav_label(:streams), do: "Streams"
  defp nav_label(:creators), do: "Creators"
  defp nav_label(:videos), do: "Videos"
  defp nav_label(:shop_analytics), do: "Analytics"
  defp nav_label(:admin), do: "Admin"
  defp nav_label(_), do: "Menu"

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
  DEPRECATED: This function does not work as heroicons are not installed.

  Use inline SVGs instead:

      <svg class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
        <path d="..." />
      </svg>

  For icon paths, see https://feathericons.com or similar SVG icon libraries.
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

  attr :click_away_disabled, :boolean,
    default: false,
    doc: "Disable click-away behavior (useful when external elements like pickers are open)"

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
            phx-click-away={!@click_away_disabled && JS.exec("data-cancel", to: "##{@id}")}
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
      Gettext.dngettext(SocialObjectsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SocialObjectsWeb.Gettext, "errors", msg, opts)
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

  def format_relative_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_naive()
    |> format_relative_time()
  end

  def format_relative_time(%NaiveDateTime{} = datetime) do
    now = NaiveDateTime.utc_now()
    diff_seconds = NaiveDateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        "Just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes} #{pluralize("minute", minutes)} ago"

      diff_seconds < 86_400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} #{pluralize("hour", hours)} ago"

      diff_seconds < 172_800 ->
        "Yesterday"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86_400)
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

  def pluralize(word, 1), do: word
  def pluralize(word, _), do: "#{word}s"
end
