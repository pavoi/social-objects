defmodule PavoiWeb.CreatorTagComponents do
  @moduledoc """
  Tag management components for creator CRM.
  """
  use Phoenix.Component
  import PavoiWeb.CoreComponents

  @doc """
  Renders tag pills for a creator's tags.

  ## Examples

      <.tag_pills tags={@creator.creator_tags} />
  """
  attr :tags, :list, default: []
  attr :max_visible, :integer, default: 3
  attr :in_table, :boolean, default: false

  def tag_pills(assigns) do
    visible_tags = Enum.take(assigns.tags || [], assigns.max_visible)
    remaining_count = max(0, length(assigns.tags || []) - assigns.max_visible)
    assigns = assign(assigns, visible_tags: visible_tags, remaining_count: remaining_count)

    ~H"""
    <%= if @tags && @tags != [] do %>
      <div
        class={["tag-pills", @in_table && "tag-pills--table"]}
        data-total-tags={length(@tags || [])}
      >
        <%= for tag <- @visible_tags do %>
          <%= if is_binary(tag) do %>
            <span class="tag-pill tag-pill--gray" data-tag>{tag}</span>
          <% else %>
            <span class={"tag-pill tag-pill--#{tag.color}"} data-tag>{tag.name}</span>
          <% end %>
        <% end %>
        <%= if @remaining_count > 0 && !@in_table do %>
          <span class="tag-pill tag-pill--more">+{@remaining_count}</span>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a clickable tag cell for the creator table.

  Shows existing tags with a click handler to open the tag picker.
  """
  attr :creator, :any, required: true

  def tag_cell(assigns) do
    creator_tags = assigns.creator.creator_tags || []
    assigns = assign(assigns, :creator_tags, creator_tags)

    ~H"""
    <div
      id={"tag-cell-#{@creator.id}"}
      class="tag-cell"
      data-tag-cell-id={@creator.id}
      phx-click="open_tag_picker"
      phx-value-creator-id={@creator.id}
      phx-hook="TagOverflow"
    >
      <%= if @creator_tags == [] do %>
        <span class="tag-cell__placeholder">Add tags</span>
      <% else %>
        <.tag_pills tags={@creator_tags} max_visible={10} in_table={true} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the tag picker dropdown.
  """
  attr :creator_id, :any, required: true
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []
  attr :search_query, :string, default: ""
  attr :new_tag_color, :string, default: "gray"

  def tag_picker(assigns) do
    search_query = assigns.search_query || ""

    filtered_tags =
      if search_query == "" do
        assigns.available_tags
      else
        query = String.downcase(search_query)

        Enum.filter(assigns.available_tags, fn tag ->
          String.contains?(String.downcase(tag.name), query)
        end)
      end

    # Sort applied tags to the top
    selected_ids = assigns.selected_tag_ids || []

    filtered_tags =
      Enum.sort_by(filtered_tags, fn tag ->
        if tag.id in selected_ids, do: 0, else: 1
      end)

    # Check if search query exactly matches an existing tag
    exact_match =
      search_query != "" &&
        Enum.any?(assigns.available_tags, fn tag ->
          String.downcase(tag.name) == String.downcase(search_query)
        end)

    # Show quick create when searching and no exact match exists
    show_quick_create =
      search_query != "" && !exact_match && String.length(String.trim(search_query)) > 0

    assigns =
      assigns
      |> assign(:filtered_tags, filtered_tags)
      |> assign(:show_quick_create, show_quick_create)
      |> assign(:search_query, search_query)

    ~H"""
    <div id="tag-picker" class="tag-picker" data-creator-id={@creator_id} phx-hook="ConfirmDelete">
      <div class="tag-picker__search">
        <input
          id="tag-picker-input"
          type="text"
          placeholder="Search or create tag..."
          value={@search_query}
          phx-keyup="search_tags"
          phx-debounce="150"
          maxlength="20"
        />
      </div>

      <%!-- Inline create option when typing a new tag name --%>
      <%= if @show_quick_create do %>
        <div class="tag-picker__quick-create">
          <div class="tag-picker__quick-create-row">
            <div class="tag-picker__quick-colors">
              <%= for color <- ~w(amber blue green red purple gray) do %>
                <button
                  type="button"
                  class={[
                    "tag-picker__quick-color",
                    "color-accent--#{color}",
                    @new_tag_color == color && "tag-picker__quick-color--selected"
                  ]}
                  phx-click="select_new_tag_color"
                  phx-value-color={color}
                  title={String.capitalize(color)}
                />
              <% end %>
            </div>
            <button
              type="button"
              class={["tag-picker__quick-create-btn", "color-accent--#{@new_tag_color}"]}
              phx-click="quick_create_tag"
              phx-value-creator-id={@creator_id}
              phx-value-name={@search_query}
              phx-value-color={@new_tag_color}
            >
              <span>Create "<strong>{@search_query}</strong>"</span>
            </button>
          </div>
        </div>
      <% end %>

      <div class="tag-picker__list">
        <%= if @filtered_tags == [] && !@show_quick_create do %>
          <div class="tag-picker__empty">
            No tags yet. Type to create one.
          </div>
        <% else %>
          <%= for tag <- @filtered_tags do %>
            <div
              class={["tag-picker__item", tag.id in @selected_tag_ids && "tag-picker__item--selected"]}
              phx-click="toggle_tag"
              phx-value-creator-id={@creator_id}
              phx-value-tag-id={tag.id}
            >
              <div class="tag-picker__item-check">
                <%= if tag.id in @selected_tag_ids do %>
                  <.icon name="hero-check" class="size-4" />
                <% end %>
              </div>
              <div class={"tag-picker__item-color color-accent--#{tag.color}"}></div>
              <span class="tag-picker__item-name">{tag.name}</span>
              <%= if tag.id in @selected_tag_ids do %>
                <button
                  type="button"
                  class="tag-picker__item-delete"
                  phx-click="toggle_tag"
                  phx-value-creator-id={@creator_id}
                  phx-value-tag-id={tag.id}
                  title="Remove tag"
                >
                  ×
                </button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the tag filter dropdown for the table header.
  """
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []

  def tag_filter(assigns) do
    selected_count = length(assigns.selected_tag_ids)
    assigns = assign(assigns, :selected_count, selected_count)

    ~H"""
    <div class="tag-filter">
      <button
        type="button"
        class={["tag-filter__trigger", @selected_count > 0 && "tag-filter__trigger--active"]}
      >
        <.icon name="hero-tag" class="size-4" />
        <span>
          <%= if @selected_count > 0 do %>
            Tags ({@selected_count})
          <% else %>
            Tags
          <% end %>
        </span>
        <%= if @selected_count > 0 do %>
          <span class="tag-filter__clear-x" phx-click="clear_tag_filter" title="Clear filter">×</span>
        <% else %>
          <.icon name="hero-chevron-down" class="size-4" />
        <% end %>
      </button>

      <div id="tag-filter-dropdown" class="tag-filter__dropdown" phx-hook="ConfirmDelete">
        <%= if @available_tags == [] do %>
          <div class="tag-filter__empty">No tags available</div>
        <% else %>
          <div class="tag-filter__list">
            <%= for tag <- @available_tags do %>
              <div class="tag-filter__item">
                <label class="tag-filter__item-label">
                  <input
                    type="checkbox"
                    checked={tag.id in @selected_tag_ids}
                    phx-click="toggle_filter_tag"
                    phx-value-tag-id={tag.id}
                  />
                  <div class={"tag-filter__item-color color-accent--#{tag.color}"}></div>
                  <span class="tag-filter__item-name">{tag.name}</span>
                </label>
                <button
                  type="button"
                  class="tag-picker__item-delete"
                  phx-click="delete_tag"
                  phx-value-tag-id={tag.id}
                  title="Delete tag"
                >
                  ×
                </button>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a batch tag picker modal content for applying tags to multiple creators.
  """
  attr :available_tags, :list, default: []
  attr :selected_tag_ids, :list, default: []
  attr :creator_count, :integer, default: 0

  def batch_tag_picker(assigns) do
    ~H"""
    <div class="batch-tag-picker">
      <div class="modal__header">
        <h2 class="modal__title">Add Tags to {@creator_count} Creators</h2>
      </div>
      <div class="modal__body">
        <%= if @available_tags == [] do %>
          <div class="batch-tag-picker__empty">
            <p>No tags available.</p>
            <p class="text-secondary text-sm">
              Create tags by clicking on the Tags column in the table.
            </p>
          </div>
        <% else %>
          <p class="text-secondary" style="margin-bottom: var(--space-3);">
            Select tags to add to the selected creators:
          </p>
          <div class="batch-tag-picker__list">
            <%= for tag <- @available_tags do %>
              <label class="batch-tag-picker__item">
                <input
                  type="checkbox"
                  checked={tag.id in @selected_tag_ids}
                  phx-click="toggle_batch_tag"
                  phx-value-tag-id={tag.id}
                />
                <div class={"tag-picker__item-color color-accent--#{tag.color}"}></div>
                <span class="batch-tag-picker__item-name">{tag.name}</span>
              </label>
            <% end %>
          </div>
        <% end %>
      </div>
      <div class="modal__footer">
        <.button variant="outline" phx-click="close_batch_tag_picker">Cancel</.button>
        <.button
          variant="primary"
          phx-click="apply_batch_tags"
          disabled={@selected_tag_ids == [] || @available_tags == []}
        >
          Apply Tags ({length(@selected_tag_ids)})
        </.button>
      </div>
    </div>
    """
  end
end
