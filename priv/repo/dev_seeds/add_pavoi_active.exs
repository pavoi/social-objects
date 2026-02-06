alias Pavoi.{Repo, Catalog, Accounts}
alias Pavoi.Catalog.Brand

# Create Pavoi Active brand
IO.puts("Creating Pavoi Active brand...")

case Catalog.create_brand(%{name: "Pavoi Active", slug: "pavoi-active"}) do
  {:ok, brand} ->
    IO.puts("Created brand: #{brand.name} (id: #{brand.id}, slug: #{brand.slug})")

    # Associate the existing user with this brand
    user = Repo.get!(Accounts.User, 1)
    IO.puts("Adding user #{user.email} to brand...")

    case Accounts.create_user_brand(user, brand, "admin") do
      {:ok, user_brand} ->
        IO.puts("Created user_brand relationship with role: #{user_brand.role}")

      {:error, changeset} ->
        IO.puts("Error creating user_brand: #{inspect(changeset.errors)}")
    end

  {:error, changeset} ->
    IO.puts("Error creating brand: #{inspect(changeset.errors)}")
end

# Verify the result
IO.puts("\n--- Final State ---")
brands = Catalog.list_brands()
IO.puts("Brands: #{Enum.map(brands, & &1.name) |> Enum.join(", ")}")

user = Accounts.get_user_with_brands!(1)

IO.puts(
  "User brands: #{Enum.map(user.user_brands, fn ub -> "#{ub.brand.name} (#{ub.role})" end) |> Enum.join(", ")}"
)
