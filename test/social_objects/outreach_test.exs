defmodule SocialObjects.OutreachTest do
  use SocialObjects.DataCase

  alias SocialObjects.Catalog
  alias SocialObjects.Creators
  alias SocialObjects.Outreach

  describe "can_contact_email?/1" do
    test "returns true for creator with email and not opted out" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "test_user",
          email: "test@example.com",
          email_opted_out: false
        })

      assert Outreach.can_contact_email?(creator)
    end

    test "returns false for creator who has opted out" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "opted_out_user",
          email: "optedout@example.com",
          email_opted_out: true
        })

      refute Outreach.can_contact_email?(creator)
    end

    test "returns false for creator with nil email" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "no_email_user",
          email: nil
        })

      refute Outreach.can_contact_email?(creator)
    end

    test "returns false for creator with empty email" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "empty_email_user",
          email: ""
        })

      refute Outreach.can_contact_email?(creator)
    end
  end

  describe "mark_email_opted_out/2" do
    test "marks creator as opted out with reason" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "to_opt_out",
          email: "willoptout@example.com",
          email_opted_out: false
        })

      {:ok, updated} = Outreach.mark_email_opted_out(creator, "unsubscribe")

      assert updated.email_opted_out == true
      assert updated.email_opted_out_reason == "unsubscribe"
      assert updated.email_opted_out_at != nil
    end

    test "does not update already opted out creator" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "already_opted",
          email: "already@example.com",
          email_opted_out: true,
          email_opted_out_reason: "spam_report",
          email_opted_out_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, unchanged} = Outreach.mark_email_opted_out(creator, "unsubscribe")

      # Should keep original reason
      assert unchanged.email_opted_out_reason == "spam_report"
    end
  end

  describe "mark_email_opted_out_by_email/2" do
    test "finds creator by email and opts them out" do
      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "findme",
          email: "FindMe@Example.COM",
          email_opted_out: false
        })

      # Case-insensitive match
      {:ok, updated} = Outreach.mark_email_opted_out_by_email("findme@example.com", "hard_bounce")

      assert updated.id == creator.id
      assert updated.email_opted_out == true
      assert updated.email_opted_out_reason == "hard_bounce"
    end

    test "returns nil when email not found" do
      {:ok, nil} =
        Outreach.mark_email_opted_out_by_email("nonexistent@example.com", "unsubscribe")
    end
  end

  describe "unsubscribe tokens" do
    test "generates and verifies valid token" do
      creator_id = 12_345

      token = Outreach.generate_unsubscribe_token(creator_id)
      assert is_binary(token)

      {:ok, verified_id} = Outreach.verify_unsubscribe_token(token)
      assert verified_id == creator_id
    end

    test "rejects invalid token" do
      result = Outreach.verify_unsubscribe_token("invalid_token")
      assert {:error, :invalid} = result
    end
  end

  describe "log_outreach/4" do
    test "creates outreach log entry" do
      {:ok, brand} =
        Catalog.create_brand(%{name: "Test Brand", slug: unique_brand_slug("outreach")})

      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "log_test",
          email: "logtest@example.com"
        })

      {:ok, log} =
        Outreach.log_outreach(brand.id, creator.id, :email, :sent,
          provider_id: "sg_abc123",
          lark_preset: "jewelry"
        )

      assert log.creator_id == creator.id
      assert log.channel == :email
      assert log.status == :sent
      assert log.provider_id == "sg_abc123"
      assert log.lark_preset == "jewelry"
    end
  end

  describe "touchpoint summary automation" do
    test "updates brand_creator touchpoint only for successful sends and newer timestamps" do
      {:ok, brand} =
        Catalog.create_brand(%{name: "Touchpoint Brand", slug: unique_brand_slug("touchpoint")})

      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "touchpoint_test",
          email: "touchpoint@example.com"
        })

      _ = Creators.add_creator_to_brand(creator.id, brand.id)

      sent_at_old =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      sent_at_new = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} =
               Outreach.log_outreach(brand.id, creator.id, :email, :sent, sent_at: sent_at_old)

      bc = Creators.get_brand_creator(brand.id, creator.id)
      assert bc.last_touchpoint_type == :email
      assert DateTime.compare(bc.last_touchpoint_at, sent_at_old) == :eq

      # Older successful touchpoint should not override summary
      older_sms = DateTime.add(sent_at_old, -600, :second)

      assert {:ok, _} =
               Outreach.log_outreach(brand.id, creator.id, :sms, :delivered, sent_at: older_sms)

      bc = Creators.get_brand_creator(brand.id, creator.id)
      assert bc.last_touchpoint_type == :email
      assert DateTime.compare(bc.last_touchpoint_at, sent_at_old) == :eq

      # Newer successful touchpoint should update summary
      assert {:ok, _} =
               Outreach.log_outreach(brand.id, creator.id, :sms, :delivered, sent_at: sent_at_new)

      bc = Creators.get_brand_creator(brand.id, creator.id)
      assert bc.last_touchpoint_type == :sms
      assert DateTime.compare(bc.last_touchpoint_at, sent_at_new) == :eq
    end

    test "ignores failed and bounced statuses for touchpoint summary" do
      {:ok, brand} =
        Catalog.create_brand(%{
          name: "Touchpoint Brand 2",
          slug: unique_brand_slug("touchpoint-2")
        })

      {:ok, creator} =
        Creators.create_creator(%{
          tiktok_username: "touchpoint_ignore",
          email: "touchpoint-ignore@example.com"
        })

      _ = Creators.add_creator_to_brand(creator.id, brand.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, _} = Outreach.log_outreach(brand.id, creator.id, :email, :failed, sent_at: now)
      assert {:ok, _} = Outreach.log_outreach(brand.id, creator.id, :sms, :bounced, sent_at: now)

      bc = Creators.get_brand_creator(brand.id, creator.id)
      assert is_nil(bc.last_touchpoint_at)
      assert is_nil(bc.last_touchpoint_type)
    end
  end

  defp unique_brand_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
