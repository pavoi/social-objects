defmodule PavoiWeb.CreatorsLive.Show do
  @moduledoc """
  LiveView for the creator detail view.

  Displays creator contact info, stats, and tabbed sections for
  samples, videos, and performance history.
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Creators
  alias Pavoi.Creators.Creator

  import PavoiWeb.CreatorComponents

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    creator = Creators.get_creator_with_details!(id)

    socket =
      socket
      |> assign(:creator, creator)
      |> assign(:active_tab, "samples")
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "samples"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/creators/#{socket.assigns.creator.id}?tab=#{tab}")}
  end

  @impl true
  def handle_event("edit_contact", _params, socket) do
    form =
      socket.assigns.creator
      |> Creator.changeset(%{})
      |> to_form()

    socket =
      socket
      |> assign(:editing_contact, true)
      |> assign(:contact_form, form)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    socket =
      socket
      |> assign(:editing_contact, false)
      |> assign(:contact_form, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_contact", %{"creator" => params}, socket) do
    changeset =
      socket.assigns.creator
      |> Creator.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :contact_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_contact", %{"creator" => params}, socket) do
    case Creators.update_creator(socket.assigns.creator, params) do
      {:ok, creator} ->
        # Reload with associations
        creator = Creators.get_creator_with_details!(creator.id)

        socket =
          socket
          |> assign(:creator, creator)
          |> assign(:editing_contact, false)
          |> assign(:contact_form, nil)
          |> put_flash(:info, "Contact info updated")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :contact_form, to_form(changeset))}
    end
  end
end
