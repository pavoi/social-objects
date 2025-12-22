defmodule Pavoi.Storage do
  @moduledoc """
  S3-compatible storage for file uploads using Railway Buckets.

  Railway Buckets use Tigris under the hood with S3-compatible APIs.
  This module handles presigned URL generation for direct browser uploads
  and public URL construction for serving files.

  ## Configuration

  Required environment variables (auto-injected by Railway when bucket is linked):
  - `RAILWAY_BUCKET_NAME` - The bucket name
  - `RAILWAY_BUCKET_ACCESS_KEY_ID` - S3 access key ID
  - `RAILWAY_BUCKET_SECRET_ACCESS_KEY` - S3 secret access key

  ## Usage

      # Generate presigned URL for upload
      {:ok, url} = Pavoi.Storage.presign_upload("sessions/123/image.webp", "image/webp")

      # Get public URL for serving
      url = Pavoi.Storage.public_url("sessions/123/image.webp")
  """

  @doc """
  Generates a presigned PUT URL for direct browser upload.

  The URL is valid for 1 hour and allows uploading a file with the specified
  content type directly from the browser.

  ## Parameters

  - `key` - The object key (path within the bucket)
  - `content_type` - The MIME type of the file being uploaded

  ## Returns

  - `{:ok, url}` - The presigned URL
  - `{:error, reason}` - If presigning fails
  """
  @spec presign_upload(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def presign_upload(key, content_type) do
    if configured?() do
      bucket = bucket_name()

      config()
      |> ExAws.S3.presigned_url(:put, bucket, key,
        expires_in: 3600,
        query_params: [{"Content-Type", content_type}]
      )
    else
      {:error,
       "Storage not configured. Ensure Railway Bucket is linked to this service."}
    end
  end

  @doc """
  Constructs a URL for a stored object.

  Since Railway Buckets are private, this returns a presigned GET URL
  that's valid for 7 days. The URL is regenerated each time, but
  since objects are cached by browsers, this is acceptable.

  ## Parameters

  - `key` - The object key (path within the bucket)

  ## Returns

  A presigned URL for viewing the object, or nil if storage isn't configured.
  """
  @spec public_url(String.t()) :: String.t() | nil
  def public_url(key_or_url) do
    # Handle both keys and full URLs (for backwards compatibility)
    key =
      if String.starts_with?(key_or_url || "", "http") do
        key_from_url(key_or_url)
      else
        key_or_url
      end

    if configured?() && key do
      bucket = bucket_name()

      case config()
           |> ExAws.S3.presigned_url(:get, bucket, key, expires_in: 604_800) do
        {:ok, url} -> url
        {:error, _} -> nil
      end
    else
      # Return a direct URL format for display even if not configured
      # (will show broken image, but won't crash)
      bucket = bucket_name() || "unconfigured"
      "https://#{bucket}.storage.railway.app/#{key}"
    end
  end

  @doc """
  Downloads an image from a URL and uploads it to storage.

  This is useful for capturing external images (like TikTok cover images)
  and storing them permanently in our storage bucket.

  ## Parameters

  - `url` - The URL to download the image from
  - `key` - The object key (path within the bucket) to store it at

  ## Returns

  - `{:ok, key}` - The storage key on success
  - `{:error, reason}` - If download or upload fails
  """
  @spec upload_from_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_from_url(url, key) do
    if configured?() do
      with {:ok, %{status: 200, body: body, headers: headers}} <- Req.get(url),
           content_type <- get_content_type(headers, url),
           {:ok, _} <- upload_binary(key, body, content_type) do
        {:ok, key}
      else
        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :storage_not_configured}
    end
  end

  defp get_content_type(headers, url) do
    # Try to get content-type from headers, fallback to guessing from URL
    case List.keyfind(headers, "content-type", 0) do
      {_, content_type} -> content_type
      nil -> guess_content_type(url)
    end
  end

  defp guess_content_type(url) do
    cond do
      String.contains?(url, ".png") -> "image/png"
      String.contains?(url, ".gif") -> "image/gif"
      String.contains?(url, ".webp") -> "image/webp"
      true -> "image/jpeg"
    end
  end

  defp upload_binary(key, binary, content_type) do
    bucket = bucket_name()

    ExAws.S3.put_object(bucket, key, binary, content_type: content_type)
    |> ExAws.request(config() |> Map.to_list())
  end

  @doc """
  Extracts the storage key from a stored URL.

  Useful for regenerating presigned URLs from stored notes_image_url values.
  """
  @spec key_from_url(String.t() | nil) :: String.t() | nil
  def key_from_url(nil), do: nil

  def key_from_url(url) when is_binary(url) do
    # URL format: https://bucket-name.storage.railway.app/key/path
    # or presigned URL with query params
    uri = URI.parse(url)

    case uri.path do
      "/" <> key -> key
      key -> key
    end
  end

  @doc """
  Checks if storage is configured.

  Returns true if all required environment variables are set.
  """
  @spec configured?() :: boolean()
  def configured? do
    bucket_name() != nil and
      access_key() != nil and
      secret_key() != nil
  end

  # Private helpers

  defp config do
    ExAws.Config.new(:s3,
      access_key_id: access_key(),
      secret_access_key: secret_key(),
      host: "storage.railway.app",
      scheme: "https://",
      region: "auto"
    )
  end

  defp bucket_name, do: System.get_env("RAILWAY_BUCKET_NAME")
  defp access_key, do: System.get_env("RAILWAY_BUCKET_ACCESS_KEY_ID")
  defp secret_key, do: System.get_env("RAILWAY_BUCKET_SECRET_ACCESS_KEY")
end
