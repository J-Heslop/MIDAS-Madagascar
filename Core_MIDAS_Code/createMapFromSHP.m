function [ locations, map, borders, mapParameters ] = createMapFromSHP( mapParameters )
%createMapFromSHP - creates a raster map of administrative units defined by the
%input shapefile and associated attribute table

%createMapFromSHP saves results in a .mat file for future use, avoiding the
%need to regenerate map each time.

%shapefile attribute table should have membership in administrative units
%denoted by variables ID_X, where lower X values are higher-order units

%shapefile should include a calculated centroid for each unit, labeled
%Latitude and Longitude

%mapParameters includes a 'density' variable that specifies the number of
%grid cells per degree Lat/Long

%returns a list of final cities and the index of their center
%(single-indexing), along with their membership in higher units

%returns a map of each administrative level

%read in the shapefile if necessary

shapeFileName = regexprep(mapParameters.filePath,'.shp','');

try
    % CACHE-CLOBBER FIX (2026-08-09).
    %
    % This was a bare `load([shapeFileName '.mat'])`. That form drops every
    % variable in the .mat into the function workspace, and the cache
    % (written by the save at the bottom of this file) contains a saved
    % `mapParameters` struct. So the load REPLACED the mapParameters passed
    % in by readParameters -- discarding every Monte Carlo draw and every
    % run_*.m override of a map parameter, silently.
    %
    % Evidence it was live rather than theoretical:
    %   - the cached struct carried filePath = './Data/Mada Boundary Files
    %     Admin 2/...', a directory that no longer exists, while
    %     readParameters sets './Data/Mada Admin 2/...'. The stale value was
    %     reaching the run.
    %   - it also carried movingCostPerMile = 0, so a local trace that set
    %     20 produced movingCost = 0 on all 5,440 away-from-home candidates.
    %   - across the 17k-run calibration, movingCostPerMile scored
    %     max|PRCC| = 0.02 over all 33 outcomes -- 3rd lowest of 69
    %     parameters, level with SD parameters that readParameters fixes at
    %     zero. minDistForCost and maxDistForCost scored 0.05 and 0.04.
    %     Migration was effectively free in every run of this model.
    %
    % Only three fields are genuinely PROPERTIES OF THE RASTERISED MAP and
    % must come from the cache, because they are computed during
    % rasterisation and the caller cannot know them:
    %   r1     spatial reference, needed to convert pixel indices to miles
    %          in createNetwork (if r1 is empty, distances stay in pixels
    %          and every pair falls below minDistForCost)
    %   sizeX  raster dimensions, set from the shapefile extent and
    %   sizeY  deliberately transposed relative to the defaults
    % Everything else -- costs, distance band, level names, save paths --
    % is the caller's and must survive.
    cached = load([shapeFileName '.mat']);
    locations = cached.locations;
    map       = cached.map;
    borders   = cached.borders;
    for fCache = {'r1', 'sizeX', 'sizeY'}
        if isfield(cached.mapParameters, fCache{1})
            mapParameters.(fCache{1}) = cached.mapParameters.(fCache{1});
        end
    end
    clear cached;
catch cacheErr
    % Report WHY the cache was not used. Previously any failure here fell
    % through silently to a rebuild, which needs the Mapping Toolbox and
    % takes several minutes -- an expensive thing to trigger by accident on
    % a cluster node, and impossible to diagnose after the fact.
    fprintf(['No usable processed map (%s).  Building from shape file ' ...
             '(This can take some time)...\n'], cacheErr.message);
    shapeData = shaperead(shapeFileName);
 
    %identify the number of levels requested
    
    structNames = fieldnames(shapeData);
    levels = structNames(contains(structNames,mapParameters.levelID));
    levelIndices = find(contains(structNames,mapParameters.levelID));
    
    [levels,indexOrder] = sort(levels);
    levelIndices = levelIndices(indexOrder);
        
    numLevels = size(levels,1);
    
    %make sure each record has the same number of levels ... where some
    %areas lack lower-level admin, just copy IDs down to the bottom.
    %structs are a pain to work with so just do this one as a for loop
    
    %update - i don't think it's a good idea to have MIDAS change data.
    %Just ask user to fix their spatial data to make sure every unit has
    %identifiers.

    idMat = struct2cell(shapeData);
    idMat = idMat';
    idMat = idMat(:,levelIndices);
    if(~isempty(find(cellfun(@isempty,idMat))))
        error('SHP file identifiers are incomplete - please fix and retry.')
    end
 
    %The algorithm reads 'units' as areas in a 2D grid that all have the same
    %value.  For each unit it sees at one scale, it will subdivide into m
    %different areas at the next scale.
    
    %To start, we make a set of map grids, one for each scale of administration
    %plus another to sit on top, just to get the algorithm started
    
    %This top layer gets values of '1' in all cells ... i.e., one 'unit'.  The
    %FIRST administrative layer in the input data (i.e., the ADM2_regions) will be
    %constructed in the second layer of this map
    
    %just remember that in this algorithm, indexI+1 refers to the map layer
    %corresponding to administrative layer indexI
    
    minX = min([shapeData(:).X]);
    maxX = max([shapeData(:).X]);
    minY = min([shapeData(:).Y]);
    maxY = max([shapeData(:).Y]);
    
    xMargin = (maxX-minX)*0.02;
    yMargin = (maxY-minY)*0.02;
    
    sizeX = ceil((maxX - minX) + 3 * xMargin) * mapParameters.density;
    sizeY = ceil((maxY - minY) + 3 * yMargin) * mapParameters.density;
    
    r1 = [mapParameters.density  maxY + yMargin minX - xMargin];
    
    map = zeros(sizeY, sizeX, numLevels + 1);
    map(:,:,1) = 1;  %this to say, the starting condition is that the map is all in one piece
    
    cityCenterLocations = [];
    
    layerNames = {};
    
    divisionCount = 0;
    
    tempMap = zeros(sizeY, sizeX);
    tempBorders = zeros(sizeY, sizeX);
    
    %add a field for the 'matrixID' ... this will be the column/row number of
    %the city in all calculations
    [shapeData(1).matrixID] = [];
    
    %start at the bottom
    totalShapes = length(shapeData);
    fprintf(['Mapping ' num2str(totalShapes) ' polygons ...']);
    newMsg = [];
    for indexJ = 1:length(shapeData) %  indexJ = 1
        outcome = vec2mtx(shapeData(indexJ).Y, shapeData(indexJ).X, tempMap, r1, 'filled');
        tempMap(outcome < 2) = indexJ;
        shapeData(indexJ).matrixID = indexJ;
        if(mod(indexJ / (floor(totalShapes / 4)),1) == 0)
            clearMsg = repmat(sprintf('\b'),1,length(newMsg)-1);
            newMsg = [num2str(floor(indexJ / totalShapes * 100)) '%%'];
            
           fprintf( [clearMsg, newMsg]);
        end
        
    end
    fprintf('\n');
    
    %assign new IDs to units to make sure they are all unique
    idCount = 0;
    adminUnits = zeros(size(shapeData,1),numLevels);
    
    %now assign maps, moving up
    lastRoundJ = zeros(length(shapeData),1);
    currentLevelIDs = num2str(lastRoundJ);
    for indexI = 2:numLevels+1
        currentLevelIDs = strcat(currentLevelIDs,'_', ({shapeData(:).(levels{indexI-1})}'));
        [bLevel,~,jLevel] = unique(currentLevelIDs,'rows');
        temp = idCount + (1:length(bLevel));
        tempIDs = temp(jLevel);
%         for indexK = 2:(indexI-1)
%             prevLevelIDs = [shapeData(:).(levels{indexK-1})];
%             [~,prevBreaks,~] = unique(prevLevelIDs);
%             for indexU = 2:length(prevBreaks)
%                tempIDs(prevBreaks(indexU):end) = tempIDs(prevBreaks(indexU):end) + (numLevels+1 - indexK) * mapParameters.colorSpacing;
%             end
%         end
        adminUnits(:,indexI-1) = tempIDs; %temp(jLevel);
        tempLayer = map(:,:,indexI);
        
        for indexJ = 1:length(shapeData)
            tempLayer(tempMap == indexJ) = tempIDs((indexJ));% + lastRoundJ(indexJ) * mapParameters.colorSpacing;
        end
        lastRoundJ = jLevel;

        map(:,:,indexI) = tempLayer ;
    
        
        
        layerNames{end+1} = ['AdminUnit' num2str(indexI-1)];
        idCount = max(max(tempLayer)) + mapParameters.colorSpacing;
    end
    
    [listY,listX] = setpostn(tempMap,r1,[shapeData(:).Latitude],[shapeData(:).Longitude]);
    
    indexLocations = sub2ind([sizeY sizeX], listY, listX);
    
    %now that we are finished, get rid of the top layer used to start the
    %algorithm
    map(:,:,1) = [];
    
    %now we identify borders as well as mark which administrative units each
    %city belongs to
    borders = zeros(size(map));
    
    %for each layer
    for indexI = 1:numLevels
        tempMap = map(:,:,indexI);
        
        %use image processing tools to identify the edges between bordering
        %units in this layer
        tempBorder = edge(tempMap,'sobel',0.1);
        tempBorder = bwmorph(tempBorder,'diag');
        borders(:,:,indexI) = tempBorder;
    end
    
    cityCenterLocations = [adminUnits(:,end) indexLocations'];
    %store locations in a dataset array
    locations = array2table([cityCenterLocations listX' listY' adminUnits], 'VariableNames',{'cityID','LocationIndex','locationX','locationY',layerNames{:}});
    
    fieldNameList = fieldnames(shapeData);
    fields_ID = contains(fieldnames(shapeData),mapParameters.levelID);
    fields_NAME = contains(fieldnames(shapeData),mapParameters.levelName);
    
    fields_keep = fields_ID | fields_NAME;
    
    addFields = struct2table(rmfield(shapeData,fieldNameList(~fields_keep)));
    addFields.Properties.VariableNames = strcat('source_',addFields.Properties.VariableNames);
    
    locations = horzcat(locations, addFields);
    
    locations.matrixID = (1:length(listX))';
    
    mapParameters.sizeX = sizeY;
    mapParameters.sizeY = sizeX;
    mapParameters.r1 = r1;
    
    % Save ONLY the geometry that rasterisation produced. Writing the whole
    % mapParameters struct is what created the clobbering bug: the cache
    % captured whichever run happened to build it, costs and all, and every
    % later run inherited that run's draw. Under a parallel calibration
    % campaign the captured values would be arbitrary. Storing three fields
    % makes the cache incapable of carrying a behavioural parameter.
    %
    % Written via a helper so the saved variable keeps the name
    % 'mapParameters' (which the load branch above and any pre-existing
    % cache both expect) WITHOUT overwriting the live struct that this
    % function has to return.
    fprintf('Saving map for re-use (geometry only: r1, sizeX, sizeY).\n');
    saveGeometryCache([shapeFileName '.mat'], locations, map, borders, ...
                      struct('sizeX', sizeY, 'sizeY', sizeX, 'r1', r1));
end

end

% =========================================================================
function saveGeometryCache(fname, locations, map, borders, mapParameters) %#ok<INUSD>
% Save the map cache. The fifth argument is named mapParameters purely so
% that save() writes it under that name, matching what the load branch
% expects, without the caller having to overwrite its own struct.
save(fname, 'locations', 'map', 'borders', 'mapParameters');
end

