defmodule Pavoi.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Pavoi.Repo

  alias Pavoi.Accounts.{BrandInvite, User, UserBrand, UserNotifier, UserToken}
  alias Pavoi.Catalog.Brand

  @invite_ttl_days 7

  ## Platform Admin

  @doc """
  Returns true if the user is a platform admin.
  """
  def platform_admin?(%User{is_admin: true}), do: true
  def platform_admin?(_), do: false

  @doc """
  Lists all users with their brand memberships preloaded.
  """
  def list_all_users do
    User
    |> preload(user_brands: :brand)
    |> order_by([u], asc: u.email)
    |> Repo.all()
  end

  @doc """
  Gets a user with their brand memberships preloaded.
  """
  def get_user_with_brands!(id) do
    User
    |> preload(user_brands: :brand)
    |> Repo.get!(id)
  end

  @doc """
  Gets the most recent session timestamp for a user.
  """
  def get_last_session_at(%User{id: user_id}) do
    from(t in UserToken,
      where: t.user_id == ^user_id and t.context == "session",
      select: max(t.inserted_at)
    )
    |> Repo.one()
  end

  @doc """
  Lists all pending (unexpired, unaccepted) invites across all brands.
  """
  def list_all_pending_invites do
    from(i in BrandInvite,
      where: is_nil(i.accepted_at),
      where: i.expires_at > ^DateTime.utc_now(),
      preload: [:brand],
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Updates a user's admin status.
  """
  def set_admin_status(%User{} = user, is_admin) when is_boolean(is_admin) do
    user
    |> Ecto.Changeset.change(is_admin: is_admin)
    |> Repo.update()
  end

  @doc """
  Removes a user from a brand.
  """
  def remove_user_from_brand(%User{} = user, %Brand{} = brand) do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id and ub.brand_id == ^brand.id
    )
    |> Repo.delete_all()
  end

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Returns true if any user exists.
  """
  def any_users? do
    Repo.exists?(from(u in User, select: 1, limit: 1))
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user and assigns them to a brand with a role.
  """
  def register_user_for_brand(attrs, %Brand{} = brand, role \\ :viewer) do
    Repo.transaction(fn ->
      with {:ok, user} <- register_user(attrs),
           {:ok, _} <- create_user_brand(user, brand, role) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  ## User brands

  @doc """
  Lists brand memberships for a user with brand preloaded.
  """
  def list_user_brands(%User{} = user) do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id,
      preload: [:brand],
      order_by: [asc: ub.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns true if the user has access to the brand.
  """
  def user_has_brand_access?(%User{} = user, %Brand{} = brand) do
    Repo.exists?(
      from(ub in UserBrand,
        where: ub.user_id == ^user.id and ub.brand_id == ^brand.id,
        select: 1,
        limit: 1
      )
    )
  end

  @doc """
  Gets the default brand for a user.
  """
  def get_default_brand_for_user(%User{} = user) do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id,
      join: b in assoc(ub, :brand),
      order_by: [asc: ub.inserted_at],
      select: b,
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Creates a user-brand relationship.
  """
  def create_user_brand(%User{} = user, %Brand{} = brand, role \\ :viewer) do
    %UserBrand{user_id: user.id, brand_id: brand.id}
    |> UserBrand.changeset(%{role: role})
    |> Repo.insert()
  end

  ## Brand invites

  @doc """
  Creates or refreshes a brand invite for the given email.

  If an invite already exists for the brand + email, it is refreshed.
  """
  def create_brand_invite(%Brand{} = brand, email, role \\ :viewer, invited_by_user \\ nil)
      when is_binary(email) do
    invited_by_user_id =
      case invited_by_user do
        %User{id: id} -> id
        _ -> nil
      end

    attrs = %{
      brand_id: brand.id,
      email: String.downcase(String.trim(email)),
      role: role,
      invited_by_user_id: invited_by_user_id,
      expires_at: DateTime.add(DateTime.utc_now(), @invite_ttl_days, :day),
      accepted_at: nil
    }

    case Repo.get_by(BrandInvite, brand_id: brand.id, email: attrs.email) do
      nil ->
        %BrandInvite{}
        |> BrandInvite.changeset(attrs)
        |> Repo.insert()

      invite ->
        invite
        |> BrandInvite.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Delivers a brand invite email with a signed token URL.
  """
  def deliver_brand_invite(%BrandInvite{} = invite, %Brand{} = brand, invite_url_fun)
      when is_function(invite_url_fun, 1) do
    token = generate_brand_invite_token(invite)
    UserNotifier.deliver_brand_invite(invite.email, brand, invite_url_fun.(token))
  end

  @doc """
  Generates a signed invite token for the given invite.
  """
  def generate_brand_invite_token(%BrandInvite{id: id}) do
    Phoenix.Token.sign(PavoiWeb.Endpoint, "brand_invite", id)
  end

  @doc """
  Verifies a signed invite token and returns the invite if valid.
  """
  def verify_brand_invite_token(token) when is_binary(token) do
    max_age = @invite_ttl_days * 24 * 60 * 60

    with {:ok, invite_id} <-
           Phoenix.Token.verify(PavoiWeb.Endpoint, "brand_invite", token, max_age: max_age),
         %BrandInvite{} = invite <- Repo.get(BrandInvite, invite_id) do
      {:ok, invite}
    else
      {:error, :expired} -> {:error, :expired}
      {:error, :invalid} -> {:error, :invalid}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Accepts a brand invite and ensures the user is associated to the brand.
  """
  def accept_brand_invite(token) when is_binary(token) do
    with {:ok, invite} <- verify_brand_invite_token(token),
         :ok <- ensure_invite_active(invite),
         %Brand{} = brand <- Repo.get(Brand, invite.brand_id) do
      Repo.transaction(fn ->
        user = get_or_create_user(invite.email)

        with {:ok, _} <- ensure_user_brand(user, brand, invite.role),
             {:ok, _} <- mark_invite_accepted(invite) do
          {user, brand}
        else
          {:error, reason} -> Repo.rollback(reason)
          {:ok, :already_member} -> {user, brand}
        end
      end)
      |> case do
        {:ok, {user, brand}} -> {:ok, user, brand}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_invite_active(%BrandInvite{accepted_at: %DateTime{}}), do: {:error, :accepted}

  defp ensure_invite_active(%BrandInvite{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      {:error, :expired}
    else
      :ok
    end
  end

  defp ensure_invite_active(_invite), do: :ok

  defp get_or_create_user(email) do
    case get_user_by_email(email) do
      %User{} = user ->
        user

      nil ->
        {:ok, user} = register_user(%{email: email})
        user
    end
  end

  defp ensure_user_brand(%User{} = user, %Brand{} = brand, role) do
    case Repo.get_by(UserBrand, user_id: user.id, brand_id: brand.id) do
      nil -> create_user_brand(user, brand, role)
      _existing -> {:ok, :already_member}
    end
  end

  defp mark_invite_accepted(%BrandInvite{} = invite) do
    invite
    |> BrandInvite.changeset(%{accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Pavoi.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email directly.
  """
  def update_user_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Pavoi.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Ecto.Changeset.put_change(:must_change_password, false)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
