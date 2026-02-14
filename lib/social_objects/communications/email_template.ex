defmodule SocialObjects.Communications.EmailTemplate do
  @moduledoc """
  Schema for templates stored in the database.

  Supports two types:
  - "email" - Email templates for outreach campaigns
  - "page" - Page templates for web pages like the SMS consent form

  Templates are stored as complete HTML and can be edited via
  a visual block editor (GrapesJS) in the admin interface.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type lark_preset :: :jewelry | :active | :top_creators
  @type template_type :: :email | :page

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t() | nil,
          subject: String.t() | nil,
          html_body: String.t() | nil,
          text_body: String.t() | nil,
          is_active: boolean(),
          is_default: boolean(),
          lark_preset: lark_preset(),
          type: template_type(),
          form_config: map(),
          brand_id: pos_integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @lark_presets ~w(jewelry active top_creators)a
  @template_types ~w(email page)a
  @form_config_keys ~w(button_text email_label phone_label phone_placeholder)

  schema "email_templates" do
    field :name, :string
    field :subject, :string
    field :html_body, :string
    field :text_body, :string
    field :is_active, :boolean, default: true
    field :is_default, :boolean, default: false
    field :lark_preset, Ecto.Enum, values: @lark_presets, default: :jewelry
    field :type, Ecto.Enum, values: @template_types, default: :email
    field :form_config, :map, default: %{}

    belongs_to :brand, SocialObjects.Catalog.Brand

    timestamps()
  end

  def lark_presets, do: @lark_presets
  def template_types, do: @template_types

  @doc false
  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :name,
      :subject,
      :html_body,
      :text_body,
      :is_active,
      :is_default,
      :lark_preset,
      :type,
      :form_config
    ])
    |> validate_required([:brand_id, :name, :html_body, :type])
    |> validate_subject_for_email()
    |> validate_form_config()
    |> unique_constraint([:brand_id, :name])
    |> foreign_key_constraint(:brand_id)
  end

  # Email templates require a subject line
  defp validate_subject_for_email(changeset) do
    if get_field(changeset, :type) == :email do
      validate_required(changeset, [:subject])
    else
      changeset
    end
  end

  # Validate form_config only contains allowed keys
  defp validate_form_config(changeset) do
    case get_field(changeset, :form_config) do
      nil ->
        changeset

      config when is_map(config) ->
        invalid_keys = Map.keys(config) -- @form_config_keys
        string_keys = Enum.map(@form_config_keys, &to_string/1)
        invalid_keys = invalid_keys -- string_keys

        if Enum.empty?(invalid_keys) do
          changeset
        else
          add_error(
            changeset,
            :form_config,
            "contains invalid keys: #{Enum.join(invalid_keys, ", ")}"
          )
        end

      _ ->
        add_error(changeset, :form_config, "must be a map")
    end
  end
end
