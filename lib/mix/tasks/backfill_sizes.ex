defmodule Mix.Tasks.BackfillSizes do
  @moduledoc """
  Backfill size information for existing product variants.

  Extracts size from:
  1. Shopify selected_options (Size, Ring Size, Length, Diameter)
  2. SKU pattern parsing (e.g., -Y5 = size 5)
  3. Product/variant name regex (e.g., "3.5mm Hoop")

  Also updates product size_range field based on variant sizes.

  ## Usage

      # Preview what would change (recommended first step)
      mix backfill_sizes --dry-run

      # Run the actual backfill
      mix backfill_sizes

      # Custom batch size (default: 500)
      mix backfill_sizes --batch-size 100

  ## Options

      --dry-run      Preview changes without modifying database
      --batch-size   Number of variants to process per batch (default: 500)
      --force        Reprocess ALL variants, not just those without size
  """

  use Mix.Task
  require Logger
  import Ecto.Query

  alias Pavoi.Repo
  alias Pavoi.Catalog.{Product, ProductVariant, SizeExtractor}

  @shortdoc "Backfill size data for existing product variants"

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, batch_size: :integer, force: :boolean],
        aliases: [d: :dry_run, b: :batch_size, f: :force]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 500)
    force = Keyword.get(opts, :force, false)

    Mix.shell().info(
      "Starting size backfill#{if dry_run, do: " (DRY RUN)", else: ""}#{if force, do: " (FORCE ALL)", else: ""}..."
    )

    Mix.shell().info("Batch size: #{batch_size}")
    Mix.shell().info("")

    variant_stats = backfill_variants(batch_size, dry_run, force)
    product_stats = update_product_size_ranges(dry_run)

    print_summary(variant_stats, product_stats)
  end

  defp backfill_variants(batch_size, dry_run, force) do
    # Get variants to process - all variants if force, otherwise only those without size
    # Preload product for product name fallback
    base_query = ProductVariant |> preload(:product)

    variants =
      if force do
        Repo.all(base_query)
      else
        base_query |> where([v], is_nil(v.size)) |> Repo.all()
      end

    total = length(variants)
    Mix.shell().info("Found #{total} variants without size data")

    variants
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index(1)
    |> Enum.reduce(%{processed: 0, updated: 0, skipped: 0}, fn {batch, batch_num}, acc ->
      Mix.shell().info("Processing batch #{batch_num}...")
      process_variant_batch(batch, dry_run, acc)
    end)
  end

  defp process_variant_batch(variants, dry_run, acc) do
    Enum.reduce(variants, acc, fn variant, stats ->
      product_name = if variant.product, do: variant.product.name, else: nil

      {size, size_type, size_source} =
        SizeExtractor.extract_size(
          selected_options: variant.selected_options || %{},
          sku: variant.sku,
          name: variant.title,
          product_name: product_name
        )

      stats = Map.update!(stats, :processed, &(&1 + 1))

      if size do
        maybe_update_variant(variant, size, size_type, size_source, dry_run)
        Map.update!(stats, :updated, &(&1 + 1))
      else
        Map.update!(stats, :skipped, &(&1 + 1))
      end
    end)
  end

  defp maybe_update_variant(_variant, _size, _size_type, _size_source, true = _dry_run), do: :ok

  defp maybe_update_variant(variant, size, size_type, size_source, false = _dry_run) do
    changeset =
      ProductVariant.changeset(variant, %{
        size: size,
        size_type: size_type && to_string(size_type),
        size_source: size_source && to_string(size_source)
      })

    case Repo.update(changeset) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("Failed to update variant #{variant.id}: #{inspect(err)}")
    end
  end

  defp update_product_size_ranges(dry_run) do
    products =
      Product
      |> preload(:product_variants)
      |> Repo.all()

    total = length(products)
    Mix.shell().info("")
    Mix.shell().info("Updating size_range for #{total} products...")

    Enum.reduce(products, %{updated: 0, skipped: 0}, fn product, stats ->
      size_range = SizeExtractor.compute_size_range(product.product_variants)
      sizes_with_values = Enum.filter(product.product_variants, & &1.size)
      has_size_variants = length(sizes_with_values) > 1

      if size_range do
        maybe_update_product(product, size_range, has_size_variants, dry_run)
        Map.update!(stats, :updated, &(&1 + 1))
      else
        Map.update!(stats, :skipped, &(&1 + 1))
      end
    end)
  end

  defp maybe_update_product(_product, _size_range, _has_size_variants, true = _dry_run), do: :ok

  defp maybe_update_product(product, size_range, has_size_variants, false = _dry_run) do
    changeset =
      Product.changeset(product, %{
        size_range: size_range,
        has_size_variants: has_size_variants
      })

    case Repo.update(changeset) do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("Failed to update product #{product.id}: #{inspect(err)}")
    end
  end

  defp print_summary(variant_stats, product_stats) do
    Mix.shell().info("""

    ========================================
    Backfill Complete!
    ========================================

    Variants:
      - Processed: #{variant_stats.processed}
      - With size extracted: #{variant_stats.updated}
      - No size found: #{variant_stats.skipped}

    Products:
      - With size_range set: #{product_stats.updated}
      - No sizes to compute: #{product_stats.skipped}
    """)
  end
end
