function timeUse = timeCalc(constraints, portfolio, modelParameters)
%This function returns a 1x4 vector of an agent's time use given an input
%portfolio, time constraints for each layer, and any additional time costs
%if an agent is doing both rural and urban activities in a given quarter

timeUse = zeros(1,4);

%Sum rows in constraints for active portfolio layers (starting from index 2, as index 1 represents the index of the layer)
timeUse = sum(constraints(portfolio,2:end),1); 

%Now check for any concurrent rural-urban activities
% NOTE: Madagascar model does not use the rural/urban layer distinction.
% The original Senegal code used odd-indexed layers as "rural" and
% even-indexed as "urban", but mod(portfolio,2) tests the VALUES (0 or 1),
% not the INDICES, so the original logic was always true for any non-empty
% portfolio. This block is retained but disabled for Madagascar.
%
% To re-enable for a model with a genuine rural/urban split, replace with:
%   oddIdx  = mod(1:length(portfolio), 2) == 1;
%   tempRural = any(portfolio & oddIdx);
%   tempUrban = any(portfolio & ~oddIdx);
%   if tempRural && tempUrban
%       timeUse(indexQ) = timeUse(indexQ) + modelParameters.ruralUrbanTime;
%   end

end