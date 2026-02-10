defmodule Pavoi.Repo.Migrations.AddMustChangePasswordToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :must_change_password, :boolean, default: false, null: false
    end

    # Set default password for all existing users and require password change
    # Password: "changeme123!" (12 chars, meets minimum requirement)
    default_hash = Bcrypt.hash_pwd_salt("changeme123!")

    execute """
    UPDATE users
    SET hashed_password = '#{default_hash}',
        must_change_password = true
    """
  end

  def down do
    alter table(:users) do
      remove :must_change_password
    end
  end
end
