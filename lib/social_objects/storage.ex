defmodule SocialObjects.Storage do
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
      {:ok, url} = SocialObjects.Storage.presign_upload("sessions/123/image.webp", "image/webp")

      # Get public URL for serving
      url = SocialObjects.Storage.public_url("sessions/123/image.webp")
  """

  require Logger

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
      {:error, "Storage not configured. Ensure Railway Bucket is linked to this service."}
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

  A presigned URL for viewing the object, a local uploads URL, or nil if
  storage isn't configured.
  """
  @spec public_url(String.t() | nil) :: String.t() | nil
  def public_url(nil), do: nil
  def public_url(""), do: nil
  def public_url("/uploads/" <> _ = path), do: path
  def public_url("uploads/" <> _ = path), do: "/" <> path
  def public_url("/images/" <> _ = path), do: path
  def public_url("images/" <> _ = path), do: "/" <> path

  def public_url(key_or_url) do
    # Handle both keys and full URLs (for backwards compatibility)
    key =
      if String.starts_with?(key_or_url, "http") do
        key_from_url(key_or_url)
      else
        key_or_url
      end

    if configured?() && key do
      bucket = bucket_name()

      # Generate presigned URL valid for 7 days
      case config()
           |> ExAws.S3.presigned_url(:get, bucket, key, expires_in: 604_800) do
        {:ok, url} -> url
        {:error, _} -> nil
      end
    else
      nil
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
      try do
        with {:ok, body, content_type} <- fetch_url(url),
             {:ok, _} <- upload_binary(key, body, content_type) do
          {:ok, key}
        else
          {:error, reason} -> {:error, reason}
        end
      rescue
        e ->
          Logger.error("Exception in upload_from_url: #{inspect(e)}")
          {:error, {:exception, e}}
      end
    else
      {:error, :storage_not_configured}
    end
  end

  @doc """
  Stores a creator avatar either in the bucket or locally.

  Returns the storage key or local uploads path.
  """
  @spec store_creator_avatar(String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()} | :skip
  def store_creator_avatar(url, creator_id) do
    storage_requested = creator_avatar_storage_enabled?()
    storage_enabled = storage_requested && configured?()
    local_enabled = creator_avatar_local_storage_enabled?()

    cond do
      not is_binary(url) or url == "" ->
        :skip

      storage_enabled ->
        store_creator_avatar_in_storage(url, creator_id)

      local_enabled ->
        store_creator_avatar_locally(url, creator_id)

      storage_requested ->
        {:error, :storage_not_configured}

      true ->
        :skip
    end
  end

  @doc """
  Stores a video thumbnail in the bucket.

  Downloads the thumbnail from the given URL and uploads it to storage
  with a key based on the video ID.

  Returns the storage key or :skip if storage is not configured/URL is empty.
  """
  @spec store_video_thumbnail(String.t() | nil, pos_integer()) ::
          {:ok, String.t()} | {:error, term()} | :skip
  def store_video_thumbnail(url, video_id) do
    if configured?() and is_binary(url) and url != "" do
      with {:ok, body, content_type} <- fetch_url(url),
           extension <- content_type_extension(content_type),
           key <- "thumbnails/videos/#{video_id}.#{extension}",
           {:ok, _} <- upload_binary(key, body, content_type) do
        {:ok, key}
      end
    else
      :skip
    end
  end

  defp get_content_type(headers, url) do
    # Try to get content-type from headers, fallback to guessing from URL
    # Req returns headers as a map with list values
    case Map.get(headers, "content-type") do
      [content_type | _] -> content_type
      content_type when is_binary(content_type) -> content_type
      _ -> guess_content_type(url)
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

  defp fetch_url(url) do
    with {:ok, %{status: 200, body: body, headers: headers}} <- Req.get(url),
         content_type <- get_content_type(headers, url) do
      {:ok, body, content_type}
    else
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_creator_avatar_in_storage(url, creator_id) do
    key = "avatars/creators/#{creator_id}.webp"

    case upload_from_url(url, key) do
      {:ok, _key} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_creator_avatar_locally(url, creator_id) do
    with {:ok, body, content_type} <- fetch_url(url),
         extension <- content_type_extension(content_type),
         relative_path <- local_avatar_relative_path(creator_id, extension),
         absolute_path <- local_avatar_absolute_path(relative_path),
         :ok <- File.mkdir_p(Path.dirname(absolute_path)),
         :ok <- File.write(absolute_path, body) do
      {:ok, relative_path}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error("Exception in store_creator_avatar_locally: #{inspect(e)}")
      {:error, {:exception, e}}
  end

  defp content_type_extension(content_type) do
    case normalize_content_type(content_type) do
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "image/jpg" -> "jpg"
      "image/jpeg" -> "jpg"
      _ -> "jpg"
    end
  end

  defp normalize_content_type(content_type) do
    content_type
    |> String.split(";")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp local_avatar_relative_path(creator_id, extension) do
    "uploads/avatars/creators/#{creator_id}.#{extension}"
  end

  defp local_avatar_absolute_path(relative_path) do
    priv_dir = :code.priv_dir(:social_objects) |> to_string()
    Path.join([priv_dir, "static", relative_path])
  end

  @doc """
  Uploads binary data directly to storage.

  ## Parameters

  - `key` - The object key (path within the bucket)
  - `binary` - The binary data to upload
  - `content_type` - The MIME type

  ## Returns

  - `{:ok, key}` - The storage key on success
  - `{:error, reason}` - If upload fails
  """
  @spec upload_binary(String.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def upload_binary(key, binary, content_type) do
    if configured?() do
      bucket = bucket_name()

      case ExAws.S3.put_object(bucket, key, binary, content_type: content_type)
           |> ExAws.request(config() |> Map.to_list()) do
        {:ok, _} -> {:ok, key}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :storage_not_configured}
    end
  end

  @doc """
  Downloads a file from storage by its key.

  Returns the binary content of the file.

  ## Parameters

  - `key` - The object key (path within the bucket)

  ## Returns

  - `{:ok, binary}` - The file content on success
  - `{:error, reason}` - If download fails
  """
  @spec download(String.t()) :: {:ok, binary()} | {:error, term()}
  def download(key) do
    case public_url(key) do
      nil ->
        {:error, :storage_not_configured}

      url ->
        case Req.get(url, finch: SocialObjects.Finch, receive_timeout: 30_000) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status}} -> {:error, {:http_error, status}}
          {:error, reason} -> {:error, reason}
        end
    end
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
  Controls whether creator avatars should be stored in the bucket.

  Defaults to true via application config and can be overridden by setting
  `PAVOI_CREATOR_AVATAR_STORAGE` to "true"/"false".
  """
  @spec creator_avatar_storage_enabled?() :: boolean()
  def creator_avatar_storage_enabled? do
    case System.get_env("PAVOI_CREATOR_AVATAR_STORAGE") do
      "true" ->
        true

      "1" ->
        true

      "false" ->
        false

      "0" ->
        false

      _ ->
        Keyword.get(
          Application.get_env(:social_objects, :creator_avatars, []),
          :store_in_storage,
          true
        )
    end
  end

  @doc """
  Controls whether creator avatars should be stored locally.

  Defaults to false via application config and can be overridden by setting
  `PAVOI_CREATOR_AVATAR_LOCAL` to "true"/"false".
  """
  @spec creator_avatar_local_storage_enabled?() :: boolean()
  def creator_avatar_local_storage_enabled? do
    case System.get_env("PAVOI_CREATOR_AVATAR_LOCAL") do
      "true" ->
        true

      "1" ->
        true

      "false" ->
        false

      "0" ->
        false

      _ ->
        Keyword.get(
          Application.get_env(:social_objects, :creator_avatars, []),
          :store_locally,
          false
        )
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
