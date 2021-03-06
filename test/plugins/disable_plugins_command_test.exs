## The contents of this file are subject to the Mozilla Public License
## Version 1.1 (the "License"); you may not use this file except in
## compliance with the License. You may obtain a copy of the License
## at http://www.mozilla.org/MPL/
##
## Software distributed under the License is distributed on an "AS IS"
## basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
## the License for the specific language governing rights and
## limitations under the License.
##
## The Original Code is RabbitMQ.
##
## The Initial Developer of the Original Code is GoPivotal, Inc.
## Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.

defmodule DisablePluginsCommandTest do
  use ExUnit.Case, async: false
  import TestHelper

  @command RabbitMQ.CLI.Plugins.Commands.DisableCommand

  setup_all do
    RabbitMQ.CLI.Core.Distribution.start()
    node = get_rabbit_hostname()

    {:ok, plugins_file} = :rabbit_misc.rpc_call(node,
                                                :application, :get_env,
                                                [:rabbit, :enabled_plugins_file])
    {:ok, plugins_dir} = :rabbit_misc.rpc_call(node,
                                               :application, :get_env,
                                               [:rabbit, :plugins_dir])
    rabbitmq_home = :rabbit_misc.rpc_call(node, :code, :lib_dir, [:rabbit])

    {:ok, [enabled_plugins]} = :file.consult(plugins_file)

    opts = %{enabled_plugins_file: plugins_file,
             plugins_dir: plugins_dir,
             rabbitmq_home: rabbitmq_home,
             online: false, offline: false,
             all: false}

    on_exit(fn ->
      set_enabled_plugins(enabled_plugins, :online, get_rabbit_hostname(), opts)
    end)

    {:ok, opts: opts}
  end

  setup context do
    set_enabled_plugins([:rabbitmq_stomp, :rabbitmq_federation],
                        :online,
                        get_rabbit_hostname(),
                        context[:opts])


    {
      :ok,
      opts: Map.merge(context[:opts], %{
              node: get_rabbit_hostname(),
              timeout: 1000
            })
    }
  end

  test "validate: specifying both --online and --offline is reported as invalid", context do
    assert match?(
      {:validation_failure, {:bad_argument, _}},
      @command.validate(["a"], Map.merge(context[:opts], %{online: true, offline: true}))
    )
  end

  test "validate: not specifying plugins to enable is reported as invalid", context do
    assert match?(
      {:validation_failure, :not_enough_arguments},
      @command.validate([], Map.merge(context[:opts], %{online: true, offline: false}))
    )
  end

  test "validate_execution_environment: not specifying an enabled_plugins_file is reported as an error", context do
    assert @command.validate_execution_environment(["a"], Map.delete(context[:opts], :enabled_plugins_file)) ==
      {:validation_failure, :no_plugins_file}
  end

  test "validate_execution_environment: not specifying a plugins_dir is reported as an error", context do
    assert @command.validate_execution_environment(["a"], Map.delete(context[:opts], :plugins_dir)) ==
      {:validation_failure, :no_plugins_dir}
  end

  test "validate_execution_environment: specifying a non-existent enabled_plugins_file is fine", context do
    assert @command.validate_execution_environment(["a"], Map.merge(context[:opts], %{enabled_plugins_file: "none"})) == :ok
  end

  test "validate_execution_environment: specifying a non-existent plugins_dir is reported as an error", context do
    assert @command.validate_execution_environment(["a"], Map.merge(context[:opts], %{plugins_dir: "none"})) ==
      {:validation_failure, :plugins_dir_does_not_exist}
  end

  test "validate_execution_environment: failure to load the rabbit application is reported as an error", context do
    assert {:validation_failure, {:unable_to_load_rabbit, _}} =
      @command.validate_execution_environment(["a"], Map.delete(context[:opts], :rabbitmq_home))
  end

  test "node is unaccessible, writes out enabled plugins file and returns implicitly enabled plugin list", context do
    assert {:stream, test_stream} =
      @command.run(["rabbitmq_stomp"], Map.merge(context[:opts], %{node: :nonode}))
    assert [[:rabbitmq_federation],
            %{mode: :offline, disabled: [:rabbitmq_stomp], set: [:rabbitmq_federation]}] ==
      Enum.to_list(test_stream)
    assert {:ok, [[:rabbitmq_federation]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert [:amqp_client, :rabbitmq_federation, :rabbitmq_stomp] ==
           Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, []))
  end

  test "in offline mode, writes out enabled plugins and reports implicitly enabled plugin list", context do
    assert {:stream, test_stream} = @command.run(["rabbitmq_stomp"], Map.merge(context[:opts], %{offline: true, online: false}))
    assert [[:rabbitmq_federation],
            %{mode: :offline, disabled: [:rabbitmq_stomp], set: [:rabbitmq_federation]}] == Enum.to_list(test_stream)
    assert {:ok, [[:rabbitmq_federation]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert [:amqp_client, :rabbitmq_federation, :rabbitmq_stomp] ==
           Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, []))
  end

  test "in offline mode , removes implicitly enabled plugins when last explicitly enabled one is removed", context do
    assert {:stream, test_stream0} =
      @command.run(["rabbitmq_federation"], Map.merge(context[:opts], %{offline: true, online: false}))
    assert [[:rabbitmq_stomp],
            %{mode: :offline, disabled: [:rabbitmq_federation], set: [:rabbitmq_stomp]}] == Enum.to_list(test_stream0)
    assert {:ok, [[:rabbitmq_stomp]]} == :file.consult(context[:opts][:enabled_plugins_file])

    assert {:stream, test_stream1} =
      @command.run(["rabbitmq_stomp"], Map.merge(context[:opts], %{offline: true, online: false}))
    assert [[],
            %{mode: :offline, disabled: [:rabbitmq_stomp], set: []}] ==
      Enum.to_list(test_stream1)
    assert {:ok, [[]]} = :file.consult(context[:opts][:enabled_plugins_file])
  end

  test "updates plugin list and stops disabled plugins", context do
    assert {:stream, test_stream0} =
      @command.run(["rabbitmq_stomp"], context[:opts])
    assert [[:rabbitmq_federation],
            %{mode: :online,
              started: [], stopped: [:rabbitmq_stomp],
              disabled: [:rabbitmq_stomp],
              set: [:rabbitmq_federation]}] ==
      Enum.to_list(test_stream0)
    assert {:ok, [[:rabbitmq_federation]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert [:amqp_client, :rabbitmq_federation] ==
           Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, []))

    assert {:stream, test_stream1} =
      @command.run(["rabbitmq_federation"], context[:opts])
    assert [[],
            %{mode: :online,
              started: [], stopped: [:rabbitmq_federation],
              disabled: [:rabbitmq_federation],
              set: []}] ==
      Enum.to_list(test_stream1)
    assert {:ok, [[]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert Enum.empty?(Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, [])))
  end

  test "can disable multiple plugins at once", context do
    assert {:stream, test_stream} =
      @command.run(["rabbitmq_stomp", "rabbitmq_federation"], context[:opts])
    assert [[],
            %{mode: :online,
              started: [], stopped: [:rabbitmq_federation, :rabbitmq_stomp],
              disabled: [:rabbitmq_federation, :rabbitmq_stomp],
              set: []}] ==
      Enum.to_list(test_stream)
    assert {:ok, [[]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert Enum.empty?(Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, [])))
  end

  test "disabling a dependency disables all plugins that depend on it", context do
    assert {:stream, test_stream} = @command.run(["amqp_client"], context[:opts])
    assert [[],
            %{mode: :online,
              started: [], stopped: [:rabbitmq_federation, :rabbitmq_stomp],
              disabled: [:rabbitmq_federation, :rabbitmq_stomp],
              set: []}] ==
      Enum.to_list(test_stream)
    assert {:ok, [[]]} == :file.consult(context[:opts][:enabled_plugins_file])
    assert Enum.empty?(Enum.sort(:rabbit_misc.rpc_call(context[:opts][:node], :rabbit_plugins, :active, [])))
  end

end
