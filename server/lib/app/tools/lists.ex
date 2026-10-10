defmodule App.Tools.Lists do
  @moduledoc """
  The lists tool: add/check/read/clear/remove on named lists ("books" — Groceries, Plants — vs
  the generic default "To-do"). Lists are SHARED BY DEFAULT (the household book), flipping
  reminders' personal default — `App.Lists.Target` resolves who a call lands on; every result
  reports `list`/`assigned` so the brain reads it back ("added butter to the household groceries
  book").
  """
  @behaviour App.Tools.Tool

  alias App.Lists
  alias App.Lists.Target
  alias App.Users

  @default_list "To-do"

  @impl true
  def declarations do
    [
      %{
        name: "add_to_list",
        description:
          "Add one or more items to a list. Use a named list for a domain \"book\" " <>
            "(groceries, plants); omit `list` for the generic to-do list. Lists are SHARED by " <>
            "default. Several items at once (a recipe's ingredients) go in ONE call via `items`.",
        parameters: %{
          type: "object",
          properties: %{
            item: %{
              type: "string",
              description: "The item to add, e.g. \"butter\" or \"call the plumber\"."
            },
            items: %{
              type: "array",
              items: %{type: "string"},
              description: "Several items to add in one call, e.g. a recipe's ingredients."
            },
            list: %{
              type: "string",
              description:
                "The list/book name, e.g. \"groceries\". Omit for the generic to-do list."
            },
            for: %{
              type: "string",
              description:
                "Who the list belongs to. Omit for the shared household list (the default). " <>
                  "Use \"me\"/\"my\" for personal. Use a person's name (\"David\"/\"Tanya\") for theirs."
            }
          },
          required: []
        }
      },
      %{
        name: "check_off",
        description:
          "Mark an item on a list as done (check it off) — the item stays, struck through.",
        parameters: %{
          type: "object",
          properties: %{
            item: %{type: "string", description: "The item to check off, e.g. \"milk\"."},
            list: %{
              type: "string",
              description: "The list/book name. Omit for the generic to-do list."
            }
          },
          required: ["item"]
        }
      },
      %{
        name: "read_list",
        description:
          "Read back the items on a list (unchecked first, checked items shown as done).",
        parameters: %{
          type: "object",
          properties: %{
            list: %{
              type: "string",
              description: "The list/book name. Omit for the generic to-do list."
            }
          },
          required: []
        }
      },
      %{
        name: "clear_checked",
        description: "Delete the checked-off (done) items on a list.",
        parameters: %{
          type: "object",
          properties: %{
            list: %{
              type: "string",
              description: "The list/book name. Omit for the generic to-do list."
            }
          },
          required: []
        }
      },
      %{
        name: "remove_item",
        description: "Remove an item from a list entirely (not just check it off).",
        parameters: %{
          type: "object",
          properties: %{
            item: %{type: "string", description: "The item to remove, e.g. \"milk\"."},
            list: %{
              type: "string",
              description: "The list/book name. Omit for the generic to-do list."
            }
          },
          required: ["item"]
        }
      }
    ]
  end

  @impl true
  def execute("add_to_list", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — item not saved"}}

  def execute("add_to_list", args, ctx) do
    case items_to_add(args) do
      [] ->
        {:error, :missing_args}

      texts ->
        target = resolve_target(args["for"], ctx)
        list = Lists.find_or_create_list(target, list_name(args))
        added = for t <- texts, {:ok, item} <- [Lists.add_item(list, t)], do: item.text

        case added do
          [] ->
            {:error, :invalid_item}

          [first | _] ->
            # The list's contents ride along so the client can show the updated list as a
            # card (App.Cards) — "added butter" is better SEEN on the groceries list itself.
            items = Lists.with_items(list).items

            {:ok,
             %{
               item: first,
               added: added,
               list: list.name,
               household: list.household,
               assigned: target.assigned,
               items: Enum.map(items, &%{text: &1.text, checked: &1.checked_at != nil})
             }}
        end
    end
  end

  def execute("check_off", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to check off"}}

  def execute("check_off", %{"item" => phrase} = args, ctx) do
    list = Lists.find_or_create_list(default_target(ctx), list_name(args))

    case Lists.find_item(list, phrase) do
      nil ->
        {:ok, %{note: "no item by that name on #{list.name} — nothing to check off"}}

      found ->
        {:ok, checked} = Lists.check_item(found)
        {:ok, %{checked: checked.text, list: list.name}}
    end
  end

  def execute("check_off", _args, _ctx), do: {:error, :missing_args}

  def execute("read_list", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to read"}}

  def execute("read_list", args, ctx) do
    list =
      default_target(ctx)
      |> Lists.find_or_create_list(list_name(args))
      |> Lists.with_items()

    case list.items do
      [] ->
        {:ok, %{list: list.name, items: [], note: "nothing on #{list.name} yet"}}

      items ->
        {:ok,
         %{
           list: list.name,
           household: list.household,
           items: Enum.map(items, &%{text: &1.text, checked: &1.checked_at != nil})
         }}
    end
  end

  def execute("clear_checked", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to clear"}}

  def execute("clear_checked", args, ctx) do
    list = Lists.find_or_create_list(default_target(ctx), list_name(args))
    count = Lists.clear_checked(list)
    {:ok, %{list: list.name, cleared: count}}
  end

  def execute("remove_item", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to remove"}}

  def execute("remove_item", %{"item" => phrase} = args, ctx) do
    list = Lists.find_or_create_list(default_target(ctx), list_name(args))

    case Lists.find_item(list, phrase) do
      nil ->
        {:ok, %{note: "no item by that name on #{list.name} — nothing to remove"}}

      found ->
        {:ok, removed} = Lists.remove_item(found)
        {:ok, %{removed: removed.text, list: list.name}}
    end
  end

  def execute("remove_item", _args, _ctx), do: {:error, :missing_args}

  # `item` and/or `items`, trimmed, blanks dropped, de-duplicated case-insensitively (a recipe
  # that lists "salt" twice still adds it once).
  defp items_to_add(args) do
    many = if is_list(args["items"]), do: args["items"], else: []
    one = if is_binary(args["item"]), do: [args["item"]], else: []

    (many ++ one)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp list_name(args) do
    case args["list"] do
      nil -> @default_list
      "" -> @default_list
      name -> name
    end
  end

  defp resolve_target(for_arg, ctx) do
    Target.resolve(for_arg, %{
      session_user_id: uid(ctx),
      gate_on: App.Config.default().household_named_targets,
      users: Enum.filter(Users.list(), &Users.allowed?(&1.email))
    })
  end

  defp default_target(ctx), do: resolve_target(nil, ctx)

  defp uid(%{user_id: uid}), do: uid
end
