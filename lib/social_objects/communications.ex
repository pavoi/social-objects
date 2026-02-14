defmodule SocialObjects.Communications do
  @moduledoc """
  The Communications context manages email templates and related functionality.
  """

  import Ecto.Query, warn: false

  alias SocialObjects.Communications.EmailTemplate
  alias SocialObjects.Repo

  ## Email Templates

  @spec list_email_templates(pos_integer()) :: [EmailTemplate.t()]
  @doc """
  Lists all active email templates, ordered by name.
  """
  def list_email_templates(brand_id) do
    list_templates_by_type(brand_id, "email")
  end

  @spec list_all_email_templates(pos_integer()) :: [EmailTemplate.t()]
  @doc """
  Lists all email templates including inactive ones.
  """
  def list_all_email_templates(brand_id) do
    list_all_templates_by_type(brand_id, "email")
  end

  @spec list_templates_by_type(pos_integer(), String.t()) :: [EmailTemplate.t()]
  @doc """
  Lists active templates of a specific type, ordered by name.
  """
  def list_templates_by_type(brand_id, type) when type in ["email", "page"] do
    from(t in EmailTemplate,
      where: t.brand_id == ^brand_id and t.type == ^type and t.is_active == true,
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  @spec list_all_templates_by_type(pos_integer(), String.t()) :: [EmailTemplate.t()]
  @doc """
  Lists all templates of a specific type including inactive ones, ordered by name.
  """
  def list_all_templates_by_type(brand_id, type) when type in ["email", "page"] do
    from(t in EmailTemplate,
      where: t.brand_id == ^brand_id and t.type == ^type,
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  @spec get_email_template!(pos_integer(), pos_integer()) :: EmailTemplate.t() | no_return()
  @doc """
  Gets a single email template by ID.

  Raises `Ecto.NoResultsError` if the template does not exist.
  """
  @spec get_email_template!(pos_integer(), pos_integer()) :: EmailTemplate.t()
  def get_email_template!(brand_id, id),
    do: Repo.get_by!(EmailTemplate, id: id, brand_id: brand_id)

  @spec get_email_template_by_name(pos_integer(), String.t()) :: EmailTemplate.t() | nil
  @doc """
  Gets a single email template by name.

  Returns nil if not found or inactive.
  """
  def get_email_template_by_name(brand_id, name) do
    Repo.get_by(EmailTemplate, brand_id: brand_id, name: name, is_active: true)
  end

  @spec get_default_email_template(pos_integer()) :: EmailTemplate.t() | nil
  @doc """
  Gets the default email template.

  Returns nil if no default is set.
  """
  def get_default_email_template(brand_id) do
    Repo.get_by(EmailTemplate,
      brand_id: brand_id,
      type: "email",
      is_default: true,
      is_active: true
    )
  end

  @spec get_default_page_template(pos_integer(), String.t()) :: EmailTemplate.t() | nil
  @doc """
  Gets the default page template for a specific lark preset.

  Returns nil if no default is set for that preset.
  """
  def get_default_page_template(brand_id, lark_preset) do
    Repo.get_by(EmailTemplate,
      brand_id: brand_id,
      type: :page,
      lark_preset: lark_preset,
      is_default: true,
      is_active: true
    )
  end

  @spec create_email_template(pos_integer(), map()) ::
          {:ok, EmailTemplate.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Creates an email template.
  """
  def create_email_template(brand_id, attrs \\ %{}) do
    %EmailTemplate{brand_id: brand_id}
    |> EmailTemplate.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_email_template(EmailTemplate.t(), map()) ::
          {:ok, EmailTemplate.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Updates an email template.
  """
  def update_email_template(%EmailTemplate{} = template, attrs) do
    template
    |> EmailTemplate.changeset(attrs)
    |> Repo.update()
  end

  @spec duplicate_email_template(pos_integer(), pos_integer()) ::
          {:ok, EmailTemplate.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Duplicates an email template for a brand.

  The duplicate copies all template content but is always active and non-default.
  """
  def duplicate_email_template(brand_id, template_id) do
    source_template = get_email_template!(brand_id, template_id)

    attrs = %{
      name: next_duplicate_template_name(brand_id, source_template.name),
      subject: source_template.subject,
      html_body: source_template.html_body,
      text_body: source_template.text_body,
      is_active: true,
      is_default: false,
      lark_preset: source_template.lark_preset,
      type: source_template.type,
      form_config: source_template.form_config
    }

    create_email_template(brand_id, attrs)
  end

  @spec set_default_template(EmailTemplate.t()) :: {:ok, EmailTemplate.t()} | {:error, term()}
  @doc """
  Sets a template as the default, clearing any existing default.

  For page templates, only clears default within the same type+lark_preset combo.
  For email templates, clears all email defaults (backwards compatible).
  """
  def set_default_template(%EmailTemplate{} = template) do
    Repo.transaction(fn ->
      # Clear existing default for same type (and lark_preset for page templates)
      template
      |> build_clear_default_query()
      |> Repo.update_all(set: [is_default: false])

      # Set new default
      template
      |> EmailTemplate.changeset(%{is_default: true})
      |> Repo.update!()
    end)
  end

  defp build_clear_default_query(%EmailTemplate{type: :page} = template) do
    from(t in EmailTemplate,
      where:
        t.brand_id == ^template.brand_id and
          t.type == ^template.type and
          t.lark_preset == ^template.lark_preset and
          t.is_default == true
    )
  end

  defp build_clear_default_query(%EmailTemplate{} = template) do
    from(t in EmailTemplate,
      where:
        t.brand_id == ^template.brand_id and
          t.type == ^template.type and
          t.is_default == true
    )
  end

  defp next_duplicate_template_name(brand_id, source_name, attempt \\ 1) do
    candidate_name =
      if attempt == 1 do
        "Copy of #{source_name}"
      else
        "Copy of #{source_name} (#{attempt})"
      end

    if template_name_taken?(brand_id, candidate_name) do
      next_duplicate_template_name(brand_id, source_name, attempt + 1)
    else
      candidate_name
    end
  end

  defp template_name_taken?(brand_id, name) do
    from(t in EmailTemplate,
      where: t.brand_id == ^brand_id and t.name == ^name
    )
    |> Repo.exists?()
  end

  @spec delete_email_template(EmailTemplate.t()) ::
          {:ok, EmailTemplate.t()} | {:error, Ecto.Changeset.t()}
  @doc """
  Deletes an email template.
  """
  def delete_email_template(%EmailTemplate{} = template) do
    Repo.delete(template)
  end

  @spec change_email_template(EmailTemplate.t(), map()) :: Ecto.Changeset.t()
  @doc """
  Returns an `%Ecto.Changeset{}` for tracking template changes.
  """
  def change_email_template(%EmailTemplate{} = template, attrs \\ %{}) do
    EmailTemplate.changeset(template, attrs)
  end
end
