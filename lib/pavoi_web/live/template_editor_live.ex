defmodule PavoiWeb.TemplateEditorLive do
  @moduledoc """
  Full-page LiveView for editing templates with GrapesJS.

  Supports two template types:
  - "email" - Email templates for outreach campaigns
  - "page" - Page templates for web pages like the SMS consent form

  Routes:
  - /templates/new          - Create new email template
  - /templates/new?type=page - Create new page template
  - /templates/:id/edit     - Edit existing template
  """
  use PavoiWeb, :live_view

  on_mount {PavoiWeb.NavHooks, :set_current_page}

  alias Pavoi.Communications
  alias Pavoi.Communications.EmailTemplate
  alias PavoiWeb.BrandRoutes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    # Support ?type=page query param for page templates
    template_type = params["type"] || "email"
    brand_id = socket.assigns.current_brand.id
    template = %EmailTemplate{brand_id: brand_id, lark_preset: "jewelry", type: template_type}
    changeset = Communications.change_email_template(template)

    page_title =
      if template_type == "page", do: "New Page Template", else: "New Email Template"

    socket
    |> assign(:page_title, page_title)
    |> assign(:template, template)
    |> assign(:template_type, template_type)
    |> assign(:form, to_form(changeset))
    |> assign(:is_new, true)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    brand_id = socket.assigns.current_brand.id
    template = Communications.get_email_template!(brand_id, id)
    changeset = Communications.change_email_template(template)

    page_title =
      if template.type == "page", do: "Edit Page Template", else: "Edit Email Template"

    socket
    |> assign(:page_title, page_title)
    |> assign(:template, template)
    |> assign(:template_type, template.type)
    |> assign(:form, to_form(changeset))
    |> assign(:is_new, false)
  end

  @impl true
  def handle_event("validate", %{"email_template" => params}, socket) do
    changeset =
      socket.assigns.template
      |> Communications.change_email_template(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("template_html_updated", %{"html" => html} = params, socket)
      when is_binary(html) and html != "" do
    # Extract form_config if present (for page templates)
    form_config = Map.get(params, "form_config", %{})

    # Update the form with the HTML from the visual editor
    current_params = %{
      "name" => socket.assigns.form[:name].value || "",
      "subject" => socket.assigns.form[:subject].value || "",
      "lark_preset" => socket.assigns.form[:lark_preset].value || "jewelry",
      "type" => socket.assigns.template_type,
      "html_body" => html,
      "form_config" => form_config
    }

    changeset = Communications.change_email_template(socket.assigns.template, current_params)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  # Ignore empty or missing HTML updates (happens during editor initialization)
  def handle_event("template_html_updated", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"email_template" => params}, socket) do
    # Decode form_config if it's a JSON string
    params = decode_form_config(params)
    brand_id = socket.assigns.current_brand.id

    result =
      if socket.assigns.is_new do
        Communications.create_email_template(brand_id, params)
      else
        Communications.update_email_template(socket.assigns.template, params)
      end

    case result do
      {:ok, _template} ->
        socket =
          socket
          |> put_flash(:info, "Template saved successfully")
          |> push_navigate(
            to:
              BrandRoutes.brand_path(
                socket.assigns.current_brand,
                "/creators?pt=templates",
                socket.assigns.current_host
              )
          )

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Decode form_config from JSON string if needed
  defp decode_form_config(%{"form_config" => config} = params) when is_binary(config) do
    case Jason.decode(config) do
      {:ok, decoded} -> Map.put(params, "form_config", decoded)
      _ -> params
    end
  end

  defp decode_form_config(params), do: params
end
