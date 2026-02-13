# New Brand Onboarding Checklist

Use this checklist when onboarding a new brand. Items marked **(Required)** are blocking; items marked **(If applicable)** depend on which features you want active for the brand.

---

## TikTok Shop Authorization (Required)

- [ ] **Shop Owner performs OAuth authorization** — The TikTok Shop Owner's main account (not a sub-account or admin) must authorize your app. Sub-accounts cannot authorize third-party services.
- [ ] **Confirm shop region** — Is this a US shop or Global? Select the correct region in the admin brands settings modal before generating the authorization link.
  - US: `https://services.us.tiktokshop.com/open/authorize?...`
  - Global: `https://services.tiktokshop.com/open/authorize?...`
- [ ] **Verify app scopes** — Before the shop authorizes, confirm your TikTok Partner Center app has the necessary scopes enabled (at minimum: Shop Authorized Information, Order Information, Product Basic, Affiliate Seller/Marketplace Creators). Scopes are configured at `partner.tiktokshop.com` (or `partner.us.tiktokshop.com` for US).
- [ ] **Verify redirect URL** — Your app's OAuth redirect URL (`/tiktok/callback`) must be registered in the TikTok Partner Center app settings before the shop can authorize.
- [ ] **Send authorization link** — From the admin brands page, click Settings on the brand, select the correct region, and either click "Connect TikTok Shop" or copy the link to send to the shop owner.
- [ ] **Confirm tokens received** — After authorization, the system exchanges the returned `auth_code` for `access_token`/`refresh_token` and stores them with the `brand_id`. Verify the connection shows as "Connected" in brand settings.
- [ ] **Verify shop details** — Confirm the shop name, shop ID, and region are displayed correctly in the brand settings modal.

---

## Shopify Store (If applicable — product sync)

- [ ] **Confirm store ownership** — Is the Shopify store in the same Shopify organization as your app? Custom apps can only be installed on stores within the same org. If not, you'll need to use the OAuth authorization-code flow instead of client credentials.
- [ ] **Provide store subdomain** — e.g., `theirbrand.myshopify.com`
- [ ] **Configure store credentials** — Add the Shopify store name, client ID, and client secret in the brand settings.
- [ ] **Configure product filters** — If multiple brands share one Shopify store, use include/exclude tags to filter which products sync to each brand.

---

## BigQuery (If applicable — order sync / analytics)

- [ ] **Confirm data source** — Is order data in a separate BigQuery project/dataset, or will it be added to the existing dataset with brand filtering?
- [ ] **Provide service account access** — If separate project: grant your GCP service account `roles/bigquery.dataViewer` on their dataset. Share the project ID and dataset name.
- [ ] **Configure BigQuery settings** — Add the project ID, dataset, service account email, and private key in the brand settings.
- [ ] **Confirm table schema** — Verify the BigQuery table structure matches expected schema (`TikTokShopOrders`, `TikTokShopOrderLineItems`), or document any differences.

---

## SendGrid (If applicable — outreach emails)

- [ ] **Brand-specific sender identity** — Configure the desired `from_name` and `from_email` in brand settings.
- [ ] **Domain verification** — Verify the sender domain in SendGrid (or use a shared verified domain with a brand-specific from address).

---

## Slack (If applicable — alerts and notifications)

- [ ] **Brand-specific Slack channel** — Configure the channel name where alerts should be routed for this brand.
- [ ] **Bot token** — If using a separate workspace, configure the Slack bot token. If using the same workspace, just the channel is sufficient.
- [ ] **Dev user ID** — Optionally configure a Slack user ID for development notifications.

---

## Brand Configuration (Internal)

- [ ] **Create brand record** — Add the brand to the `brands` table with `name`, `slug`, and `primary_domain` (if applicable).
- [ ] **Assign users** — Create user-brand relationships in `user_brands` with appropriate roles (owner/admin/member).
- [ ] **Create user accounts** — Create users with password auth and assign them to the brand.
- [ ] **Configure brand settings** — Set up all applicable integrations via the admin brands settings modal.
- [ ] **Custom domain (if applicable)** — Set the brand's primary domain, configure DNS to point to the app, and ensure SSL is configured.
- [ ] **TikTok Live accounts** — Configure which TikTok accounts to monitor for live streams.

---

## Validation

- [ ] **Verify data isolation** — Confirm that all queries, workers, and API calls for this brand are scoped correctly and no data leaks to/from other brands.
- [ ] **Test product sync** — Run Shopify and/or TikTok Shop product sync and verify products appear correctly.
- [ ] **Test stream monitoring** — Start a test live stream and verify it's captured for the correct brand.
- [ ] **Test outreach** — Send a test outreach email and verify it uses the correct sender identity.
- [ ] **Test order sync** — If using BigQuery, verify order data syncs correctly for the brand.
