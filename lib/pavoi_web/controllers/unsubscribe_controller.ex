defmodule PavoiWeb.UnsubscribeController do
  use PavoiWeb, :controller

  alias Pavoi.Catalog
  alias Pavoi.Outreach
  alias Pavoi.Repo
  alias Pavoi.Settings

  @doc """
  Handles unsubscribe requests from email links.
  Shows a confirmation page after unsubscribing.
  """
  def unsubscribe(conn, %{"token" => token}) do
    with {:ok, payload} <- Outreach.verify_unsubscribe_token(token),
         {creator_id, brand} <- resolve_payload(payload),
         %{} = creator <- Repo.get(Pavoi.Creators.Creator, creator_id),
         {:ok, _} <- Outreach.mark_email_opted_out(creator, "unsubscribe") do
      render_success(conn, creator.email, brand)
    else
      {:error, :expired} -> render_error(conn, "This unsubscribe link has expired.")
      {:error, :invalid} -> render_error(conn, "This unsubscribe link is invalid.")
      {:error, _} -> render_error(conn, "Something went wrong. Please try again later.")
      nil -> render_error(conn, "This unsubscribe link is no longer valid.")
    end
  end

  defp render_success(conn, email, brand) do
    brand_name = brand_name(brand)

    html(conn, """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Unsubscribed - #{brand_name}</title>
      <style>
        body {
          font-family: Georgia, 'Times New Roman', serif;
          background: #f8f8f8;
          margin: 0;
          padding: 40px 20px;
          color: #2E4042;
        }
        .container {
          max-width: 500px;
          margin: 0 auto;
          background: #fff;
          padding: 40px;
          text-align: center;
        }
        h1 {
          font-size: 24px;
          font-weight: normal;
          margin: 0 0 20px;
        }
        p {
          line-height: 1.6;
          color: #666;
        }
        .email {
          font-weight: bold;
          color: #2E4042;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>You've been unsubscribed</h1>
        <p>
          <span class="email">#{html_escape(email)}</span> has been removed from our mailing list.
        </p>
        <p>You won't receive any more emails from us.</p>
      </div>
    </body>
    </html>
    """)
  end

  defp render_error(conn, message) do
    brand_name = brand_name(nil)

    conn
    |> put_status(400)
    |> html("""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Unsubscribe Error - #{brand_name}</title>
      <style>
        body {
          font-family: Georgia, 'Times New Roman', serif;
          background: #f8f8f8;
          margin: 0;
          padding: 40px 20px;
          color: #2E4042;
        }
        .container {
          max-width: 500px;
          margin: 0 auto;
          background: #fff;
          padding: 40px;
          text-align: center;
        }
        h1 {
          font-size: 24px;
          font-weight: normal;
          margin: 0 0 20px;
        }
        p {
          line-height: 1.6;
          color: #666;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Unsubscribe Error</h1>
        <p>#{html_escape(message)}</p>
      </div>
    </body>
    </html>
    """)
  end

  defp resolve_payload(%{creator_id: creator_id, brand_id: brand_id}) do
    {creator_id, Catalog.get_brand(brand_id)}
  end

  defp resolve_payload(creator_id) when is_integer(creator_id) do
    {creator_id, nil}
  end

  defp resolve_payload(_payload), do: {nil, nil}

  defp brand_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp brand_name(_), do: Settings.app_name()

  defp html_escape(nil), do: ""

  defp html_escape(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
