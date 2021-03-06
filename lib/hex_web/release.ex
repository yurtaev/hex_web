defmodule HexWeb.Release do
  use Ecto.Model

  import Ecto.Query, only: [from: 2]
  import HexWeb.Validation
  alias HexWeb.Util

  schema "releases" do
    field :app, :string
    field :version, :string
    field :checksum, :string
    field :has_docs, :boolean
    field :created_at, :datetime
    field :updated_at, :datetime

    belongs_to :package, HexWeb.Package
    has_many :requirements, HexWeb.Requirement
    has_one :downloads, HexWeb.Stats.ReleaseDownload
  end

  validatep validate(release),
    app: present() and type(:string),
    version: present() and type(:string) and valid_version(pre: true)

  validatep validate_create(release),
    also: validate(),
    also: unique([:version], scope: [:package_id], on: HexWeb.Repo)

  def create(package, version, app, requirements, checksum, created_at \\ nil) do
    now = Util.ecto_now
    release = struct(package.releases,
                     app: app,
                     version: version,
                     updated_at: now,
                     checksum: String.upcase(checksum),
                     created_at: created_at || now)

    case validate_create(release) do
      [] ->
        HexWeb.Repo.transaction(fn ->
          HexWeb.Repo.insert(release)
          |> update_requirements(requirements)
          |> Util.maybe(&Ecto.Associations.load(&1, :package, package))
        end)
      errors ->
        {:error, Enum.into(errors, %{})}
    end
  end

  def update(release, app, requirements, checksum) do
    if editable?(release) do
      case validate(release) do
        [] ->
          HexWeb.Repo.transaction(fn ->
            HexWeb.Repo.delete_all(release.requirements)
            HexWeb.Repo.delete(release)
            create(release.package.get, release.version, app, requirements,
                   checksum, release.created_at)
          end) |> elem(1)
        errors ->
          {:error, Enum.into(errors, %{})}
      end

    else
      {:error, [created_at: "can only modify a release up to one hour after creation"]}
    end
  end

  def delete(release, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    if editable?(release) or force? do
      HexWeb.Repo.transaction(fn ->
        HexWeb.Repo.delete_all(release.requirements)
        HexWeb.Repo.delete(release)
      end)

      :ok
    else
      {:error, [created_at: "can only delete a release up to one hour after creation"]}
    end
  end

  defp editable?(release) do
    created_at = Ecto.DateTime.to_erl(release.created_at)
                 |> :calendar.datetime_to_gregorian_seconds
    now = :calendar.universal_time
          |> :calendar.datetime_to_gregorian_seconds

    now - created_at <= 3600
  end

  defp update_requirements(release, requirements) do
    requirements = normalize_requirements(requirements)
    results = create_requirements(release, requirements)

    errors = Enum.filter_map(results, &match?({:error, _}, &1), &elem(&1, 1))
    if errors == [] do
      Ecto.Associations.load(release, :requirements, requirements)
    else
      HexWeb.Repo.rollback(%{deps: Enum.into(errors, %{})})
    end
  end

  defp create_requirements(release, requirements) do
    deps = Enum.map(requirements, &elem(&1, 0))

    deps_query =
         from p in HexWeb.Package,
       where: p.name in array(^deps, ^:string),
      select: {p.name, p.id}
    deps = HexWeb.Repo.all(deps_query) |> Enum.into(HashDict.new)

    Enum.map(requirements, fn {dep, app, req, optional} ->
      add_requirement(release, deps, dep, app, req, optional || false)
    end)
  end

  defp normalize_requirements(requirements) do
    Enum.map(requirements, fn
      {dep, %{"app" => app, "requirement" => req, "optional" => optional}} ->
        {to_string(dep), app, req, optional}
      # Support everything pre Hex 0.6.0 (2014-10-13)
      {dep, %{"requirement" => req, "optional" => optional}} ->
        {to_string(dep), to_string(dep), req, optional}
      {dep, {req, app}} ->
        {to_string(dep), to_string(app), req, false}
      {dep, req} ->
        {to_string(dep), to_string(dep), req, false}
    end)
  end

  def all(package) do
    HexWeb.Repo.all(package.releases)
    |> Enum.map(&Ecto.Associations.load(&1, :package, package))
    |> sort
  end

  def sort(releases) do
    releases
    |> Enum.sort(&(Version.compare(&1.version, &2.version) == :gt))
  end

  def get(package, version) do
    from(r in package.releases, where: r.version == ^version, limit: 1)
    |> HexWeb.Repo.one
    |> Util.maybe(&Ecto.Associations.load(&1, :package, package))
    |> Util.maybe(&Ecto.Associations.load(&1, :requirements, requirements(&1)))
  end

  def requirements(release) do
    from(req in release.requirements,
         join: p in req.dependency,
         select: {p.name, req.app, req.requirement, req.optional})
    |> HexWeb.Repo.all
  end

  def count do
    HexWeb.Repo.all(from(r in HexWeb.Release, select: count(r.id)))
    |> List.first
  end

  def recent(count) do
    from(r in HexWeb.Release,
         order_by: [desc: r.created_at],
         join: p in r.package,
         limit: count,
         select: {r.version, p.name})
    |> HexWeb.Repo.all
  end

  def docs_url(release) do
    HexWeb.Util.docs_url([release.package.get.name, release.version])
  end

  defp add_requirement(release, deps, dep, app, req, optional) do
    cond do
      not valid_requirement?(req) ->
        {:error, {dep, "invalid requirement: #{inspect req}"}}

      id = deps[dep] ->
        struct(release.requirements, requirement: req, app: app,
               optional: optional, dependency_id: id)
        |> HexWeb.Repo.insert()
        :ok

      true ->
        {:error, {dep, "unknown package"}}
    end
  end

  defp valid_requirement?(req) do
    is_nil(req) or (is_binary(req) and match?({:ok, _}, Version.parse_requirement(req)))
  end
end

defimpl HexWeb.Render, for: HexWeb.Release do
  import HexWeb.Util

  def render(release) do
    package = release.package.get

    reqs = for {name, app, req, optional} <- release.requirements.all, into: %{} do
      {name, %{app: app, requirement: req, optional: optional}}
    end

    dict =
      HexWeb.Release.__schema__(:keywords, release)
      |> Dict.take([:app, :version, :has_docs, :created_at, :updated_at])
      |> Dict.update!(:created_at, &to_iso8601/1)
      |> Dict.update!(:updated_at, &to_iso8601/1)
      |> Dict.put(:url, api_url(["packages", package.name, "releases", release.version]))
      |> Dict.put(:package_url, api_url(["packages", package.name]))
      |> Dict.put(:requirements, reqs)
      |> Enum.into(%{})

    if release.has_docs do
      dict = Dict.put(dict, :docs_url, HexWeb.Release.docs_url(release))
    end

    if release.downloads.loaded? do
      dict = Dict.put(dict, :downloads, release.downloads.get)
    end

    dict
  end
end
