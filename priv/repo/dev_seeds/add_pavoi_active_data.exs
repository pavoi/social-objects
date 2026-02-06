alias Pavoi.{Catalog, ProductSets}

# Get the Pavoi Active brand
brand = Catalog.get_brand_by_slug!("pavoi-active")
IO.puts("Adding sample data for: #{brand.name} (id: #{brand.id})")

# Create sample products for Pavoi Active
# Price is in cents (original_price_cents, sale_price_cents)
products = [
  %{
    name: "Performance Running Shorts",
    pid: "PA-RUN-001",
    description: "Lightweight, breathable running shorts with moisture-wicking fabric",
    original_price_cents: 5500,
    sale_price_cents: 4500
  },
  %{
    name: "Compression Leggings",
    pid: "PA-LEG-001",
    description: "High-waisted compression leggings for maximum support",
    original_price_cents: 7500,
    sale_price_cents: 6500
  },
  %{
    name: "Quick-Dry Sports Bra",
    pid: "PA-BRA-001",
    description: "Medium support sports bra with quick-dry technology",
    original_price_cents: 4000,
    sale_price_cents: 3500
  },
  %{
    name: "Mesh Panel Tank Top",
    pid: "PA-TNK-001",
    description: "Breathable tank top with mesh ventilation panels",
    original_price_cents: 3200,
    sale_price_cents: 2800
  },
  %{
    name: "Training Joggers",
    pid: "PA-JOG-001",
    description: "Comfortable joggers with zip pockets for training sessions",
    original_price_cents: 6500,
    sale_price_cents: 5500
  }
]

created_products =
  Enum.map(products, fn attrs ->
    case Catalog.get_product_by_pid(brand.id, attrs.pid) do
      nil ->
        {:ok, product} = Catalog.create_product(brand.id, attrs)
        IO.puts("  Created product: #{product.name} (#{product.pid})")
        product

      existing ->
        IO.puts("  Skipped (already exists): #{existing.name} (#{existing.pid})")
        existing
    end
  end)

IO.puts("\nCreated #{length(created_products)} products")

# Create sample product sets
product_sets = [
  %{
    name: "Morning Workout Essentials",
    slug: "morning-workout-essentials",
    notes: "Perfect for early morning runs and gym sessions"
  },
  %{
    name: "Yoga & Pilates Collection",
    slug: "yoga-pilates-collection",
    notes: "Flexible, comfortable pieces for floor exercises"
  }
]

created_sets =
  Enum.map(product_sets, fn attrs ->
    case ProductSets.product_set_name_exists?(attrs.name, brand.id) do
      false ->
        {:ok, product_set} = ProductSets.create_product_set(brand.id, attrs)
        IO.puts("  Created product set: #{product_set.name}")
        product_set

      true ->
        existing = ProductSets.get_product_set_by_slug!(brand.id, attrs.slug)
        IO.puts("  Skipped (already exists): #{existing.name}")
        existing
    end
  end)

IO.puts("\nCreated #{length(created_sets)} product sets")

# Add products to the first product set
[set1, set2] = created_sets
[p1, p2, p3, p4, p5] = created_products

# Add first 3 products to "Morning Workout Essentials"
ProductSets.add_product_to_product_set(set1.id, p1.id)
ProductSets.add_product_to_product_set(set1.id, p2.id)
ProductSets.add_product_to_product_set(set1.id, p3.id)
IO.puts("\nAdded 3 products to '#{set1.name}'")

# Add last 3 products to "Yoga & Pilates Collection"
ProductSets.add_product_to_product_set(set2.id, p3.id)
ProductSets.add_product_to_product_set(set2.id, p4.id)
ProductSets.add_product_to_product_set(set2.id, p5.id)
IO.puts("Added 3 products to '#{set2.name}'")

IO.puts("\n✓ Sample data for Pavoi Active created successfully!")
