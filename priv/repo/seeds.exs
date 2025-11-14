# Seeds for Hudson - Sample Product Data
# Run: mix run priv/repo/seeds.exs

alias Hudson.{Repo, Catalog}
alias Hudson.Catalog.{Brand, Product, ProductImage}

require Logger

IO.puts("""
╔═══════════════════════════════════════════╗
║     Hudson Database Seeding               ║
╚═══════════════════════════════════════════╝
""")

# Step 1: Clear existing data
IO.puts("Step 1: Clearing existing data...")

# Import Sessions module for clearing session data
alias Hudson.Sessions.{Session, SessionProduct, SessionState}

Repo.delete_all(SessionState)
Repo.delete_all(SessionProduct)
Repo.delete_all(Session)
Repo.delete_all(ProductImage)
Repo.delete_all(Product)
IO.puts("  ✓ Cleared sessions, products, and images")

# Step 2: Ensure brand exists
IO.puts("\nStep 2: Ensuring brand exists...")

brand =
  case Repo.get_by(Brand, slug: "pavoi") do
    nil ->
      {:ok, brand} =
        Catalog.create_brand(%{
          name: "Pavoi",
          slug: "pavoi",
          notes: "Premium jewelry brand"
        })

      IO.puts("  ✓ Created Pavoi brand")
      brand

    brand ->
      IO.puts("  ✓ Found existing Pavoi brand")
      brand
  end

# Step 3: Sample product data
IO.puts("\nStep 3: Creating sample products...")

sample_products = [
  %{
    name: "Dainty CZ Rings Bundle",
    talking_points_md: """
    - Mila & X cross ring
    - Available in 14K yellow gold and rhodium plating
    - Sizing: 4-10
    - TIKTOK EXCLUSIVE BUNDLE
    """,
    original_price_cents: 4995,
    sale_price_cents: 3995,
    pid: "1732025389156504072",
    sku: "BUNDLE-001"
  },
  %{
    name: "Heart Tennis Bracelet Set",
    talking_points_md: """
    - Heart Tennis Bracelet and Matching Heart Bezel Eternity Ring
    - 4mm heart-cut stones with 5mm band
    - Available in gold and white gold
    - Sizes 5-9
    """,
    original_price_cents: 4500,
    sale_price_cents: 3600,
    pid: "1732025453170823688",
    sku: "BUNDLE-002"
  },
  %{
    name: "U Shaped & Paperclip Necklaces",
    talking_points_md: """
    - U-shaped: 18" + 3" extender, 8mm wide
    - Paperclip: 11mm x 3.9mm links
    - Layering bundle
    """,
    original_price_cents: 4715,
    pid: "1732025444076851720",
    sku: "BUNDLE-003"
  },
  %{
    name: "Interlocked Two Toned Ring",
    talking_points_md: """
    - #1 best seller in women's band rings
    - Mixed metal design - very hot right now
    - Each band is 2mm wide
    - 100% nickel-free, hypoallergenic
    - 4.6 star rating on TikTok Shop
    """,
    original_price_cents: 1745,
    sale_price_cents: 1396,
    pid: "1730896012450828808",
    sku: "TA7"
  },
  %{
    name: "Pear Wavy Engagement Ring",
    talking_points_md: """
    - 7mm x 10mm pear cut
    - Around 2CT equivalent
    - Wavy band design
    - Sizes 5-9
    """,
    original_price_cents: 5995,
    sale_price_cents: 4796,
    pid: "1730592865399575048",
    sku: "2311-R06"
  },
  %{
    name: "Oval Eternity Band",
    talking_points_md: """
    - 5A Quality Gem Grade Cubic Zirconia
    - 5mm oval stones, 5mm band width
    - 14K Gold plated, hypoallergenic
    - Great for stacking or travel
    """,
    original_price_cents: 1595,
    sale_price_cents: 1276,
    pid: "1729554653838283272",
    sku: "TTK20C-R03"
  },
  %{
    name: "Milgrain Eternity Band",
    talking_points_md: """
    - Classic milgrain detailing
    - 5A CZ stones
    - Sizes 5-10
    """,
    original_price_cents: 1895,
    pid: "1731178897612313096",
    sku: "19B-TC20-Y6"
  },
  %{
    name: "Religious Cross Ring",
    talking_points_md: """
    - Delicate cross design
    - Available in gold and silver
    - Sizes 5-10
    """,
    original_price_cents: 1495,
    sale_price_cents: 1196,
    pid: "1731823202067780104",
    sku: "2209-R01"
  },
  %{
    name: "CZ Cross Pendant Necklace",
    talking_points_md: """
    - 14K gold plated
    - 19" sliding chain for adjustable fit
    - Perfect for layering
    """,
    original_price_cents: 1295,
    pid: "1729738235916161544",
    sku: "19B-TC08"
  },
  %{
    name: "Station Necklace",
    talking_points_md: """
    - 15" + 3" extender
    - 1.3mm delicate chain
    - 5A CZ stations
    """,
    original_price_cents: 1495,
    sale_price_cents: 1196,
    pid: "1729555020284072456",
    sku: "21A-N11"
  },
  %{
    name: "Dainty Crystal Solitaire Necklace",
    talking_points_md: """
    - 1.5 Carat (7.3mm) CZ crystal
    - 18" with 2" extender
    - 14K gold-plated setting
    - 4.7 star rating on TikTok
    - 4.4 stars on Amazon (17,000+ reviews)
    """,
    original_price_cents: 1345,
    pid: "1729555020825465352",
    sku: "19B-TC06"
  },
  %{
    name: "Station CZ Hand Bracelet",
    talking_points_md: """
    - Ring portion: 4.2", chain: 3", bracelet: 6" + 2" extender
    - 14K gold and rhodium plated
    - 2.5mm premium AAAAA Cubic Zirconia
    """,
    original_price_cents: 1395,
    sale_price_cents: 1116,
    pid: "1729560045457412616",
    sku: "TKT2401-HC01-V2"
  },
  %{
    name: "Tennis Bracelet",
    talking_points_md: """
    - Round 3mm CZ stones in four-prong settings
    - 5A CZ premium quality
    - 14K gold plated
    - Sizes: 6.5", 7", 7.5"
    - Lead-free and hypoallergenic
    """,
    original_price_cents: 1795,
    sale_price_cents: 1436,
    pid: "1729554646471512584",
    sku: "TKT19B-TC16"
  },
  %{
    name: "Emerald Cut Tennis Bracelet",
    talking_points_md: """
    - 3mm x 4mm emerald-cut stones
    - Bezel setting for modern look
    - Sizes 6" - 7.5"
    """,
    original_price_cents: 2195,
    pid: "1731392948627280392",
    sku: "2406-B05"
  },
  %{
    name: "Love Bangle",
    talking_points_md: """
    - 2.7mm premium CZ stones
    - 6mm wide bangle
    - Stainless steel construction
    - Inner diameter: 50mm x 60mm (size 7)
    """,
    original_price_cents: 3295,
    sale_price_cents: 2636,
    pid: "1731817833983414792",
    sku: "BANGLE-001"
  },
  %{
    name: "Heart Charms Bracelet Set",
    talking_points_md: """
    - Two 9" bracelets included
    - Small heart: 8mm x 6.8mm
    - Open heart: 11.8mm x 10mm
    - Went viral for mother/daughter matching
    """,
    original_price_cents: 2495,
    pid: "1730595722208973320",
    sku: "2311-R05"
  },
  %{
    name: "Oval Pull-Through Earrings",
    talking_points_md: """
    - Statement earrings: 24mm x 18mm
    - 9mm opening for easy wear
    - Sterling silver posts
    """,
    original_price_cents: 1895,
    sale_price_cents: 1516,
    pid: "1730928918542848520",
    sku: "2305-E04-Yv2"
  },
  %{
    name: "CZ Huggie Earrings Set",
    talking_points_md: """
    - Set of 3 sizes: 8mm, 10mm, 12mm
    - 18K Gold Plated
    - 925 Sterling Silver Posts
    - Hinged closure for security
    """,
    original_price_cents: 1845,
    sale_price_cents: 1476,
    pid: "1730568297058439688",
    sku: "22D-EP01"
  }
]

# Create products
products =
  Enum.map(sample_products, fn attrs ->
    {:ok, product} = Catalog.create_product(Map.put(attrs, :brand_id, brand.id))
    IO.puts("  ✓ Created product: #{product.name}")
    product
  end)

IO.puts("""

╔═══════════════════════════════════════════╗
║     Seeding Complete!                     ║
╚═══════════════════════════════════════════╝

Created:
  • #{length(products)} products
  • #{length(products)} placeholder images
  • All uploaded to Supabase

Next steps:
  1. Start the server:
     mix phx.server

  2. View products:
     http://localhost:4000/products
""")
