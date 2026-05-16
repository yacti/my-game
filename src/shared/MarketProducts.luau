local MarketProducts = {}

MarketProducts.RestockProductId = 3593513166

MarketProducts.FeedProductIds = {
	CherryTree = 3593513368,
	AppleTree = 3593513259,
}

function MarketProducts.FeedTypeForProductId(productId)
	for feedType, configuredProductId in pairs(MarketProducts.FeedProductIds) do
		if configuredProductId == productId then
			return feedType
		end
	end
	return nil
end

return MarketProducts
