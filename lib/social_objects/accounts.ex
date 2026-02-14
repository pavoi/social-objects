defmodule SocialObjects.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias SocialObjects.Repo

  alias SocialObjects.Accounts.{User, UserBrand, UserToken}
  alias SocialObjects.Catalog.Brand

  @type role :: :owner | :admin | :viewer

  ## Platform Admin

  @doc """
  Returns true if the user is a platform admin.
  """
  @spec platform_admin?(User.t() | nil) :: boolean()
  def platform_admin?(%User{is_admin: true}), do: true
  def platform_admin?(_), do: false

  @doc """
  Lists all users with their brand memberships preloaded.
  """
  @spec list_all_users() :: [User.t()]
  def list_all_users do
    User
    |> preload(user_brands: :brand)
    |> order_by([u], asc: u.email)
    |> Repo.all()
  end

  @doc """
  Gets a user with their brand memberships preloaded.
  """
  @spec get_user_with_brands!(pos_integer()) :: User.t() | no_return()
  def get_user_with_brands!(id) do
    User
    |> preload(user_brands: :brand)
    |> Repo.get!(id)
  end

  @doc """
  Gets the most recent session timestamp for a user.
  """
  @spec get_last_session_at(User.t()) :: DateTime.t() | nil
  def get_last_session_at(%User{id: user_id}) do
    from(t in UserToken,
      where: t.user_id == ^user_id and t.context == "session",
      select: max(t.inserted_at)
    )
    |> Repo.one()
  end

  @doc """
  Updates a user's admin status.
  """
  @spec set_admin_status(User.t(), boolean()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_admin_status(%User{} = user, is_admin) when is_boolean(is_admin) do
    user
    |> Ecto.Changeset.change(is_admin: is_admin)
    |> Repo.update()
  end

  @doc """
  Removes a user from a brand.
  """
  @spec remove_user_from_brand(User.t(), Brand.t()) :: {non_neg_integer(), nil | [term()]}
  def remove_user_from_brand(%User{} = user, %Brand{} = brand) do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id and ub.brand_id == ^brand.id
    )
    |> Repo.delete_all()
  end

  @doc """
  Updates the role for an existing user-brand membership.
  """
  @spec update_user_brand_role(User.t(), Brand.t(), role()) :: :ok | {:error, :not_found}
  def update_user_brand_role(%User{} = user, %Brand{} = brand, new_role)
      when new_role in [:viewer, :admin, :owner] do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id and ub.brand_id == ^brand.id
    )
    |> Repo.update_all(set: [role: new_role, updated_at: DateTime.utc_now()])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  @doc """
  Deletes a user and all associated data (tokens, brand memberships).
  """
  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete_user(%User{} = user) do
    Repo.transaction(fn ->
      # Delete all user tokens
      Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))

      # Delete all brand memberships
      Repo.delete_all(from(ub in UserBrand, where: ub.user_id == ^user.id))

      # Delete the user
      case Repo.delete(user) do
        {:ok, user} -> user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Resets a user's password to a new temporary password.
  Invalidates all existing sessions.
  Returns {:ok, user, temp_password} on success.
  """
  @spec reset_user_password(User.t()) ::
          {:ok, User.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def reset_user_password(%User{} = user) do
    temp_password = generate_temp_password()

    changeset =
      user
      |> User.password_changeset(%{password: temp_password}, hash_password: true)
      |> Ecto.Changeset.put_change(:must_change_password, true)

    Repo.transaction(fn ->
      case Repo.update(changeset) do
        {:ok, updated_user} ->
          # Delete all existing tokens to invalidate sessions
          Repo.delete_all(from(t in UserToken, where: t.user_id == ^user.id))
          {updated_user, temp_password}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {user, temp_password}} -> {:ok, user, temp_password}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Counts the number of platform admins.
  """
  @spec count_admins() :: non_neg_integer()
  def count_admins do
    from(u in User, where: u.is_admin == true, select: count(u.id))
    |> Repo.one()
  end

  @doc """
  Returns true if the user is the only platform admin.
  """
  @spec only_admin?(User.t()) :: boolean()
  def only_admin?(%User{is_admin: false}), do: false

  def only_admin?(%User{is_admin: true}) do
    count_admins() == 1
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
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Returns true if any user exists.
  """
  @spec any_users?() :: boolean()
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
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
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
  @spec get_user!(pos_integer()) :: User.t() | no_return()
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
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user and assigns them to a brand with a role.
  """
  @spec register_user_for_brand(map(), Brand.t(), role()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
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

  @doc """
  Creates a user with a temporary password.

  The user will be required to change their password on first login.
  Returns {:ok, user, temp_password} on success.
  """
  @spec create_user_with_temp_password(String.t()) ::
          {:ok, User.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_user_with_temp_password(email) when is_binary(email) do
    temp_password = generate_temp_password()

    changeset =
      %User{}
      |> User.email_changeset(%{email: email})
      |> User.password_changeset(%{password: temp_password}, hash_password: true)
      |> Ecto.Changeset.put_change(:must_change_password, true)

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, user, temp_password}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp generate_temp_password do
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64()
    |> binary_part(0, 16)
  end

  ## User brands

  @doc """
  Lists brand memberships for a user with brand preloaded.
  For admin users, returns all brands in the system.
  """
  @spec list_user_brands(User.t()) :: [UserBrand.t()] | [%{brand: Brand.t()}]
  def list_user_brands(%User{is_admin: true}) do
    # Admins have access to all brands
    SocialObjects.Catalog.list_brands()
    |> Enum.map(fn brand -> %{brand: brand} end)
  end

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
  Admin users have access to all brands.
  """
  @spec user_has_brand_access?(User.t(), Brand.t()) :: boolean()
  def user_has_brand_access?(%User{is_admin: true}, %Brand{}), do: true

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
  Gets the user's role for a brand.
  Platform admins are treated as owners for all brands.
  Returns :owner, :admin, :viewer, or nil if no access.
  """
  @spec get_user_brand_role(User.t(), Brand.t()) :: role() | nil
  def get_user_brand_role(%User{is_admin: true}, %Brand{}), do: :owner

  def get_user_brand_role(%User{} = user, %Brand{} = brand) do
    from(ub in UserBrand,
      where: ub.user_id == ^user.id and ub.brand_id == ^brand.id,
      select: ub.role
    )
    |> Repo.one()
  end

  @doc """
  Checks if a user has at least the specified role for a brand.
  Platform admins always return true.
  """
  @spec user_has_role?(User.t(), Brand.t(), role()) :: boolean()
  def user_has_role?(%User{is_admin: true}, %Brand{}, _min_role), do: true

  def user_has_role?(%User{} = user, %Brand{} = brand, min_role) do
    case get_user_brand_role(user, brand) do
      nil -> false
      role -> role_at_least?(role, min_role)
    end
  end

  defp role_at_least?(role, min_role), do: role_level(role) >= role_level(min_role)

  defp role_level(:owner), do: 3
  defp role_level(:admin), do: 2
  defp role_level(:viewer), do: 1
  defp role_level(_), do: 0

  @doc """
  Gets the default brand for a user.
  """
  @spec get_default_brand_for_user(User.t()) :: Brand.t() | nil
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
  @spec create_user_brand(User.t(), Brand.t(), role()) ::
          {:ok, UserBrand.t()} | {:error, Ecto.Changeset.t()}
  def create_user_brand(%User{} = user, %Brand{} = brand, role \\ :viewer) do
    %UserBrand{user_id: user.id, brand_id: brand.id}
    |> UserBrand.changeset(%{role: role})
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `SocialObjects.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_email(User.t(), map(), keyword()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email directly.
  """
  @spec update_user_email(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_email(user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `SocialObjects.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_password(User.t(), map(), keyword()) :: Ecto.Changeset.t()
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
  @spec update_user_password(User.t(), map()) ::
          {:ok, {User.t(), [UserToken.t()]}} | {:error, Ecto.Changeset.t()}
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Ecto.Changeset.put_change(:must_change_password, false)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Updates the user password without invalidating existing sessions.

  Use this for forced password changes (first-time login) where
  logging the user out would be unnecessary friction.

  ## Examples

      iex> update_user_password_keep_session(user, %{password: ...})
      {:ok, %User{}}

      iex> update_user_password_keep_session(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password_keep_session(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_password_keep_session(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Ecto.Changeset.put_change(:must_change_password, false)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  @spec get_user_by_session_token(binary()) :: {User.t(), DateTime.t()} | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  @spec delete_user_session_token(binary()) :: :ok
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
