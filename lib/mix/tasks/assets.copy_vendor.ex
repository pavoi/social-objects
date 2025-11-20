defmodule Mix.Tasks.Assets.CopyVendor do
  @moduledoc """
  Copies vendor WASM and model files from node_modules to priv/static.

  This task copies necessary runtime files for voice control features:
  - ONNX Runtime WASM files (for Whisper and VAD models)
  - Silero VAD model file

  These files cannot be bundled by esbuild and must be served as static assets.
  """

  use Mix.Task

  @shortdoc "Copy vendor WASM and model files to priv/static"

  def run(_args) do
    project_root = Path.expand("../../..", __DIR__)
    assets_root = Path.join(project_root, "assets")
    assets_dir = Path.join([assets_root, "node_modules"])
    static_dir = Path.join([project_root, "priv", "static"])

    ensure_node_modules!(assets_root, assets_dir)

    # Files to copy: {source_path, dest_path}
    files_to_copy = [
      # ONNX Runtime WASM files (WebGPU backend)
      {"onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.mjs",
       "assets/js/ort-wasm-simd-threaded.jsep.mjs"},
      {"onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.wasm",
       "assets/js/ort-wasm-simd-threaded.jsep.wasm"},
      # Standard WASM backend (fallback)
      {"onnxruntime-web/dist/ort-wasm-simd-threaded.mjs",
       "assets/js/ort-wasm-simd-threaded.mjs"},
      {"onnxruntime-web/dist/ort-wasm-simd-threaded.wasm",
       "assets/js/ort-wasm-simd-threaded.wasm"},
      # VAD model file
      {"@ricky0123/vad-web/dist/silero_vad.onnx", "assets/vad/silero_vad.onnx"}
    ]

    Mix.shell().info("Copying vendor files to static assets...")

    Enum.each(files_to_copy, fn {source, dest} ->
      source_path = Path.join(assets_dir, source)
      dest_path = Path.join(static_dir, dest)

      if File.exists?(source_path) do
        # Ensure destination directory exists
        dest_path |> Path.dirname() |> File.mkdir_p!()

        # Copy file
        File.cp!(source_path, dest_path)
        file_size = source_path |> File.stat!() |> Map.get(:size)
        size_mb = Float.round(file_size / 1_024 / 1_024, 1)

        Mix.shell().info("  ✓ Copied #{dest} (#{size_mb} MB)")
      else
        Mix.raise("""
        Source file not found: #{source_path}
        Confirm npm dependencies are installed and the expected file exists.
        """)
      end
    end)

    Mix.shell().info("Vendor files copied successfully!")
  end

  defp ensure_node_modules!(assets_root, assets_dir) do
    if File.dir?(assets_dir) do
      :ok
    else
      Mix.shell().info("node_modules not found; installing with npm ci --production=false...")

      case System.cmd("npm", ["ci", "--production=false"], cd: assets_root, stderr_to_stdout: true) do
        {output, 0} ->
          Mix.shell().info(output)

        {output, status} ->
          Mix.raise("""
          npm ci failed with status #{status}:
          #{output}
          """)
      end
    end
  end
end
