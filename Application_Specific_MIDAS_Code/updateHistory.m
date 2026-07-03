function utilityVariables = updateHistory(utilityVariables, modelParameters, indexT, countAgentsPerLayer)

%income functions are of the form f(k,m,nExpected,n_actual, base)
% - note that this may change depending on the simulation -
%be sure that whatever your income functions are, the cellfun input
%matches appropriately

onesList = ones(size(utilityVariables.utilityHistory,1),1);


for indexL = 1:size(utilityVariables.utilityHistory,2)
    % BUG FIX (2026-07): this previously read utilityVariables.nExpected(indexL),
    % a scalar LINEAR index into the (nLocations x nLayers) matrix. Because
    % MATLAB is column-major, layer L's income everywhere was congestion-
    % checked against nExpected(L, 1) -- i.e. location L's capacity for
    % layer 1 (unskilled1) -- broadcast to all locations. Capacity was
    % therefore location-invariant, used the wrong layer's fraction, and
    % was keyed to an arbitrary region by index coincidence (e.g. vanilla,
    % layer 9, used 0.4 x Haute_Matsiatra's population instead of
    % 0.03 x Sava's). The correct per-location capacity column is
    % nExpected(:, indexL), consistent with the hasOpenSlots calculation
    % in midasMainLoop.m.
    utilityVariables.utilityHistory(:,indexL, indexT) = arrayfun(utilityVariables.utilityLayerFunctions{indexL}, ...
        onesList*modelParameters.utility_k, ...
        onesList*modelParameters.utility_m, ...
        utilityVariables.nExpected(:,indexL), ...
        countAgentsPerLayer(:,indexL, indexT), ...
        utilityVariables.utilityBaseLayers(:,indexL,indexT));
end

end