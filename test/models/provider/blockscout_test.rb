# frozen_string_literal: true

require "test_helper"

class Provider::BlockscoutTest < ActiveSupport::TestCase
  Resp = Struct.new(:code, :parsed_response)

  test "rejects unsupported chains" do
    assert_raises(Provider::Blockscout::UnsupportedChainError) do
      Provider::Blockscout.new(chain: "dogecoin")
    end
  end

  test "validates EVM addresses" do
    provider = Provider::Blockscout.new(chain: "polygon")
    assert provider.valid_address?("0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840")
    assert_not provider.valid_address?("not-an-address")
  end

  test "get_native_balance returns the coin balance in wei" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.expects(:get).returns(Resp.new(200, { "coin_balance" => "2000000000000000000" }))

    provider = Provider::Blockscout.new(chain: "ethereum")
    assert_equal "2000000000000000000", provider.get_native_balance("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "get_erc20_transfers returns Etherscan-shaped transfers (keyless, no API key)" do
    page = {
      "items" => [
        {
          "transaction_hash" => "0xabc",
          "timestamp" => "2025-10-23T01:31:03.000000Z",
          "from" => { "hash" => "0xSENDER" },
          "to" => { "hash" => "0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840" },
          "token" => { "address_hash" => "0xC2132D05D31c914a87C6611C10748AEb04B58e8F", "symbol" => "USDT0", "decimals" => "6" },
          "total" => { "value" => "20000000", "decimals" => "6" }
        }
      ],
      "next_page_params" => nil
    }
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.expects(:get).returns(Resp.new(200, page))

    provider = Provider::Blockscout.new(chain: "polygon")
    transfers = provider.get_erc20_transfers("0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840")

    assert_equal 1, transfers.size
    t = transfers.first
    assert_equal "0xabc", t["hash"]
    assert_equal "USDT0", t["tokenSymbol"]
    assert_equal "0xC2132D05D31c914a87C6611C10748AEb04B58e8F", t["contractAddress"]
    assert_equal "20000000", t["value"]
    assert_equal "6", t["tokenDecimal"]
    assert_equal "1761183063", t["timeStamp"]
  end

  test "has_activity? costs a single request and never walks the transfer history" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.any_instance.expects(:get_erc20_transfers).never
    Provider::Blockscout.any_instance.expects(:get_normal_transactions).never
    Provider::Blockscout.expects(:get).once.returns(
      Resp.new(200, { "coin_balance" => "2000000000000000000", "has_tokens" => false, "has_token_transfers" => false })
    )

    provider = Provider::Blockscout.new(chain: "ethereum")
    assert provider.has_activity?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "has_activity? detects token-only wallets with no native balance" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.expects(:get).once.returns(
      Resp.new(200, { "coin_balance" => nil, "has_tokens" => true, "has_token_transfers" => true })
    )

    provider = Provider::Blockscout.new(chain: "polygon")
    assert provider.has_activity?("0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840")
  end

  test "has_activity? is false for an address the chain has never seen" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.expects(:get).once.returns(
      Resp.new(200, { "coin_balance" => nil, "has_tokens" => false, "has_token_transfers" => false, "has_logs" => false })
    )

    provider = Provider::Blockscout.new(chain: "base")
    assert_not provider.has_activity?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "has_activity? is false when the chain's Blockscout instance fails" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.stubs(:get).returns(Resp.new(500, nil))

    provider = Provider::Blockscout.new(chain: "gnosis", max_retries: 0)
    assert_not provider.has_activity?("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
  end

  test "has_activity? rejects malformed addresses without any request" do
    Provider::Blockscout.expects(:get).never

    provider = Provider::Blockscout.new(chain: "ethereum")
    assert_not provider.has_activity?("not-an-address")
  end

  test "raises RateLimitError on 429" do
    Provider::Blockscout.any_instance.stubs(:throttle_request)
    Provider::Blockscout.stubs(:get).returns(Resp.new(429, nil))

    provider = Provider::Blockscout.new(chain: "ethereum", max_retries: 0)
    assert_raises(Provider::Blockscout::RateLimitError) do
      provider.get_native_balance("0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae")
    end
  end
end
