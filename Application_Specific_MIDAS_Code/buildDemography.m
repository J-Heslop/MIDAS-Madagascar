function [locationLikelihood, genderLikelihood, ageLikelihood, survivalRate, fertilityRate, ageDiscountRateFactor, agePointsPopulation, agePointsSurvival, agePointsFertility, agePointsPref] = buildDemography(modelParameters, locations)

%this function can be set up however you like, but is used by MIDAS to
%establish initial distributions of agents and per-period survival in a
%particular way, so that outputs must be structured as follows:

%locationLikelihood is an n x 1 vector providing a cumulative distribution
%scaling from 0 to 1, where n is the number of places in the instance, and
%the interval between element i and the previous element is the likelihood
%of an agent being assigned to place i.  Here, i corresponds to the
%matrixID property of the locations stored in the model map.

%genderLikelihood is an n x 1 vector, in which each element i is the
%likelihood of an agent being MALE in place i

%agePoints is an m x 1 vector of ages at which likelihoods / survival /
%fertility are evaluated.  MIDAS uses interpolation to evaluate ages and survival
%probabilities, so this vector SHOULD include the minimum age (i.e., 0) and
%whatever maximum age you expect in your model.  In most cases, data will
%be in age classes, so agePoints would start with the minimum of the first
%bin and end with the maximum of the last bin.

%ageLikelihood is an n x m_1 x 2 array, where n is the number of places, m_1 is
%the number of points at which age classes are evaluated, and 2 is the
%number of sexes considered by the model (male and female).  Each m-element
%row of ageLikelihood corresponding to place i should be the cumulative
%distribution of ages, for that sex, in place i.

%survivalRate is an n x m_2 x 2 array, where n is the number of places, m_2 is
%the number of points at which age classes are evaluated, and 2 is the
%number of sexes considered by the model (male and female).  Each element
%in survival rate should show the likelihood of ANNUAL (real world years)
%survival of someone that age, sex, and in that location.  MIDAS will
%convert to per-timestep likelihoods

%fertility rate is an n x m_3 array, where n is the number of places, m_3
%is the number of points at which age classes are evaluated.  Each element
%should show the likelihood of a female agent having ONE child.  At present
%MIDAS doesn't worry about multiple births, but also doesn't preclude a
%female agent having a child each timestep, so in practice the number of
%dependents should match the statistical rates well enough

%the following code is specific to a particular input file.

%make locationLikelihood - if there is no data, let the likelihood be
%uniform random
if(~isempty(modelParameters.popFile))
    popTable = readtable(modelParameters.popFile);

    % TOTAL POPULATION COLUMN (fixed 2026-08-26). This was
    %     popTable.population = sum(popTable{:,end},2);
    % which reads whatever happens to be the LAST column. That worked only
    % while the file held nothing but totals. Adding age-sex columns made the
    % last column female100_104, so every region's population -- and hence the
    % spatial distribution of all agents -- would have become the count of
    % centenarian women. Name the column instead of relying on its position.
    if any(strcmp(popTable.Properties.VariableNames, 'x1985_pop'))
        popTable.population = popTable.x1985_pop;
    elseif any(strcmp(popTable.Properties.VariableNames, 'pop1985'))
        popTable.population = popTable.pop1985;
    else
        popCol = find(contains(popTable.Properties.VariableNames, 'pop', ...
                               'IgnoreCase', true) & ...
                      ~startsWith(popTable.Properties.VariableNames, 'male') & ...
                      ~startsWith(popTable.Properties.VariableNames, 'female'), 1);
        if isempty(popCol)
            error('buildDemography:noPopColumn', ...
                  ['No total-population column found in %s. Expected a column ' ...
                   'whose name contains "pop".'], modelParameters.popFile);
        end
        popTable.population = popTable{:, popCol};
    end

    popTable = join(popTable,locations,'LeftKeys',{'ADM2_PCODE'},'RightKeys',{'source_ADM2_PCODE'});

    % Check whether the population file contains age-sex breakdown columns.
    % NAMING: 'maleA_B' / 'femaleA_B' with NO underscore after the sex, e.g.
    % male0_4, female15_19. The parser below strips the sex prefix and takes
    % the text after the FIRST underscore, so male0_4 -> '4'. With male_0_4
    % the strip leaves '_0_4', strfind returns two underscore positions,
    % extractAfter throws, the try swallows it and str2double yields NaN.
    % (readParameters.m previously documented male_X_Y, which does not work.)
    hasMaleAgeCols   = any(startsWith(popTable.Properties.VariableNames, 'male'));
    hasFemaleAgeCols = any(startsWith(popTable.Properties.VariableNames, 'female'));

    if hasMaleAgeCols && hasFemaleAgeCols
        %variable names with age bins are of form 'maleX_Y'
        agePointsPopulationMale = popTable.Properties.VariableNames(startsWith(popTable.Properties.VariableNames,'male'));
        agePointsPopulationMale = regexprep(agePointsPopulationMale,'male','');
        for indexI = 1:size(agePointsPopulationMale,2)
            try agePointsPopulationMale{indexI} = extractAfter(agePointsPopulationMale{indexI},strfind(agePointsPopulationMale{indexI},'_'));
            end
        end
        agePointsPopulationMale = str2double(agePointsPopulationMale);
        [agePointsPopulationMale, ageIndexMale] = sort(agePointsPopulationMale,'ascend');

        agePointsPopulationFemale = popTable.Properties.VariableNames(startsWith(popTable.Properties.VariableNames,'female'));
        agePointsPopulationFemale = regexprep(agePointsPopulationFemale,'female','');
        for indexI = 1:size(agePointsPopulationFemale,2)
            try agePointsPopulationFemale{indexI} = extractAfter(agePointsPopulationFemale{indexI},strfind(agePointsPopulationFemale{indexI},'_'));
            end
        end
        agePointsPopulationFemale = str2double(agePointsPopulationFemale);
        [~, ageIndexFemale] = sort(agePointsPopulationFemale,'ascend');

        % ROW ORDERING (fixed 2026-08-26). Rows arrive in popTable order and
        % must be permuted into map order, where matrixID gives the map row for
        % each table row -- so the assignment is
        %     dest(matrixID, :) = source
        % done ONCE. The male branch did that correctly; the female branch
        % additionally indexed the source by matrixID as it read
        %     popTable{popTable.matrixID, ...}
        % applying the permutation twice, so male and female ended up on
        % different regional orderings. Both now use the same single step.
        rawMale   = popTable{:, startsWith(popTable.Properties.VariableNames, 'male')};
        rawFemale = popTable{:, startsWith(popTable.Properties.VariableNames, 'female')};

        ageLikelihoodMale = zeros(size(rawMale));
        ageLikelihoodMale(popTable.matrixID, :) = rawMale;
        ageLikelihoodMale = ageLikelihoodMale(:, ageIndexMale);

        ageLikelihoodFemale = zeros(size(rawFemale));
        ageLikelihoodFemale(popTable.matrixID, :) = rawFemale;
        ageLikelihoodFemale = ageLikelihoodFemale(:, ageIndexFemale);

        % SEX TOTALS (fixed 2026-08-26). The second of these read
        %     popTable.male = sum(ageLikelihoodFemale, 2);
        % overwriting the male total with the female sum, so genderLikelihood
        % below -- the probability an agent is MALE -- carried the FEMALE
        % share. Sex would have been inverted for every agent, and since only
        % females bear children that propagates straight into fertility.
        % These are in MAP order, matching genderLikelihood's use in buildWorld.
        maleTotal   = sum(ageLikelihoodMale,   2);
        femaleTotal = sum(ageLikelihoodFemale, 2);

        ageLikelihoodMale = cumsum(ageLikelihoodMale,2);
        ageLikelihoodMale = ageLikelihoodMale ./ (ageLikelihoodMale(:,end) * ones(1,size(ageLikelihoodMale,2)));

        ageLikelihoodFemale = cumsum(ageLikelihoodFemale,2);
        ageLikelihoodFemale = ageLikelihoodFemale ./ (ageLikelihoodFemale(:,end) * ones(1,size(ageLikelihoodFemale,2)));

        ageLikelihood = ageLikelihoodMale;
        ageLikelihood(:,:,2) = ageLikelihoodFemale;
        agePointsPopulation = agePointsPopulationMale;

        % STRICTLY INCREASING CHECK. buildWorld.m draws an age with
        %     interp1([0 ageLikelihood(loc,:,gender)], [0 agePointsPopulation], rand())
        % which requires unique sample points. An age band with zero population
        % leaves the cumulative distribution flat across it, two points
        % coincide, and interp1 throws "Sample points must be unique" from
        % inside buildWorld with no indication that the population FILE is the
        % cause. Madagascar 1985 has nobody in the 100+ band, which is exactly
        % this case. Fail here instead, naming the band.
        for iSex = 1:2
            flat = find(diff([zeros(size(ageLikelihood,1),1) ageLikelihood(:,:,iSex)], 1, 2) <= 0);
            if ~isempty(flat)
                [~, badCol] = ind2sub([size(ageLikelihood,1) size(ageLikelihood,2)], flat(1));
                sexName = {'male', 'female'};
                error('buildDemography:emptyAgeBand', ...
                      ['Age band ending %g has zero %s population in at least one ' ...
                       'region, so the cumulative age distribution is flat there ' ...
                       'and interp1 in buildWorld cannot invert it.\n' ...
                       'Remove empty bands from %s.'], ...
                      agePointsPopulation(min(badCol, numel(agePointsPopulation))), ...
                      sexName{iSex}, modelParameters.popFile);
            end
        end

        % genderLikelihood is already in map order because maleTotal and
        % femaleTotal are. The previous line
        %     genderLikelihood(popTable.matrixID) = genderLikelihood;
        % was a self-assignment through an index -- a permutation applied to a
        % variable being read and written at once, correct only when matrixID
        % is the identity.
        genderLikelihood = maleTotal ./ max(maleTotal + femaleTotal, eps);

        popTable = popTable(:,{'population','matrixID'});
    else
        % NO AGE COLUMNS. This used to warn and continue with ages drawn
        % UNIFORMLY on [0, 100] -- an initial population in which 15% of
        % agents are over 85 and the 15+ share is 0.85, against 0.53 for
        % Madagascar in 1985. The model then spent roughly 25 years converging
        % on a plausible pyramid as mortality cleared the impossible elderly
        % excess and births filled the young end. Every metric before about
        % 2010 was measuring that recovery, and the calibration pooled those
        % years into foodInsecureRate_ag.
        %
        % It ran that way from the start because the warning scrolled past in
        % logs nobody re-read. A silent fallback to a demographically
        % impossible population is not a graceful degradation, so it now stops.
        % Set allowUniformAgeFallback = true only for a deliberate test.
        if isfield(modelParameters, 'allowUniformAgeFallback') && ...
           modelParameters.allowUniformAgeFallback
            warning('buildDemography:uniformAges', ...
                    ['popFile has no maleA_B/femaleA_B columns. Ages will be ' ...
                     'UNIFORM on [0 100] -- 15+ share 0.85 vs 0.53 observed. ' ...
                     'Results before ~2010 are not interpretable.']);
            agePointsPopulation = [0 50 100];
            ageLikelihood = ones(height(locations),1) * [0 0.5 1];
            ageLikelihood(:,:,2) = ageLikelihood;
            genderLikelihood = 0.5 * ones(height(locations),1);
        else
            error('buildDemography:noAgeColumns', ...
                  ['%s has no maleA_B / femaleA_B age-sex columns.\n' ...
                   'Point modelParameters.popFile at ' ...
                   'Data/1985_MDG_GHSPop_by_age_sex.csv, or set\n' ...
                   'modelParameters.allowUniformAgeFallback = true to accept a ' ...
                   'uniform [0 100] age distribution.'], modelParameters.popFile);
        end
    end

    locationLikelihood = zeros(height(locations),1);
    locationLikelihood(popTable.matrixID) = popTable.population;
    locationLikelihood = locationLikelihood / sum(locationLikelihood);
    locationLikelihood = cumsum(locationLikelihood);
else
    locationLikelihood = ones(height(locations),1) / height(locations);
    locationLikelihood = cumsum(locationLikelihood);
    agePointsPopulation = [0 50 100];
    ageLikelihood = ones(height(locations),1) * [0 0.5 1];
    ageLikelihood(:,:,2) = ageLikelihood;
    genderLikelihood = rand(height(locations),1);
end

if(~isempty(modelParameters.survivalFile))
    
    survivalTable = readtable(modelParameters.survivalFile);

    if ismember('Year', survivalTable.Properties.VariableNames)
        % --- TIME-VARYING: pre-interpolate to one value per year between
        %     startYear and endYear, producing a 4D array (loc x age x sex x time).
        %     The CSV stores annual mortality probability (1 - 5yr_ratio^(1/5));
        %     we convert to annual survival here, matching the static convention.
        demogYears        = (modelParameters.startYear : modelParameters.endYear)';
        dataYears         = sort(unique(survivalTable.Year));
        agePointsSurvival = sort(unique(survivalTable.MaxAge))';
        numT              = length(demogYears);
        numLoc            = height(locations);
        numAgeS           = length(agePointsSurvival);

        % Build (dataYear x age) mortality matrices for each sex
        maleMortMat   = zeros(length(dataYears), numAgeS);
        femaleMortMat = zeros(length(dataYears), numAgeS);
        for iY = 1:length(dataYears)
            yearRows = survivalTable(survivalTable.Year == dataYears(iY), :);
            for iA = 1:numAgeS
                ageRow = yearRows(yearRows.MaxAge == agePointsSurvival(iA), :);
                if ~isempty(ageRow)
                    maleMortMat(iY, iA)   = ageRow.Male(1);
                    femaleMortMat(iY, iA) = ageRow.Female(1);
                end
            end
        end

        % Interpolate each age bin to annual resolution then replicate across locations
        survivalRate = zeros(numLoc, numAgeS, 2, numT);
        for iA = 1:numAgeS
            maleSurv   = 1 - interp1(dataYears, maleMortMat(:,iA),   demogYears, 'linear', 'extrap');
            femaleSurv = 1 - interp1(dataYears, femaleMortMat(:,iA), demogYears, 'linear', 'extrap');
            % Clamp to (0,1] - extrapolation can occasionally push outside range
            maleSurv   = min(1, max(0.001, maleSurv));
            femaleSurv = min(1, max(0.001, femaleSurv));
            survivalRate(:, iA, 1, :) = repmat(reshape(maleSurv,   1,1,1,numT), numLoc,1,1,1);
            survivalRate(:, iA, 2, :) = repmat(reshape(femaleSurv, 1,1,1,numT), numLoc,1,1,1);
        end

    else
        % --- STATIC (original behaviour): reshape to add a size-1 time dimension
        %     so that midasMainLoop.m can index uniformly with tIdx.
        agePointsSurvival = (survivalTable.MaxAge)';
        staticRate = ones(height(locations),1) * (survivalTable.Male)';
        staticRate(:,:,2) = ones(height(locations),1) * (survivalTable.Female)';
        survivalRate = reshape(1 - staticRate, height(locations), length(agePointsSurvival), 2, 1);
    end
else
    agePointsSurvival = agePointsPopulation;
    staticRate = 1 - rand(height(locations), length(agePointsSurvival), 2) / 200;
    survivalRate = reshape(staticRate, height(locations), length(agePointsSurvival), 2, 1);
end

if(~isempty(modelParameters.fertilityFile))
    
    fertilityTable = readtable(modelParameters.fertilityFile);

    if ismember('Year', fertilityTable.Properties.VariableNames)
        % --- TIME-VARYING: pre-interpolate to annual values, producing a 3D
        %     array (loc x age x time).  Age axis has a leading zero-fertility
        %     point prepended (matching the static convention below).
        %     CSV stores annual births per 1,000 women (already divided by 5).
        demogYears   = (modelParameters.startYear : modelParameters.endYear)';
        dataYears    = sort(unique(fertilityTable.Year));
        ageMaxPts    = sort(unique(fertilityTable.MaxAge))';
        agePointsFertility = [fertilityTable.MinAge(1) ageMaxPts]; % prepend lower bound
        numT         = length(demogYears);
        numLoc       = height(locations);
        numAgeF      = length(ageMaxPts);

        % Build (dataYear x age) matrix of annual birth rates (per woman)
        birthMat = zeros(length(dataYears), numAgeF);
        for iY = 1:length(dataYears)
            yearRows = fertilityTable(fertilityTable.Year == dataYears(iY), :);
            for iA = 1:numAgeF
                ageRow = yearRows(yearRows.MaxAge == ageMaxPts(iA), :);
                if ~isempty(ageRow)
                    birthMat(iY, iA) = ageRow.Births(1) / 1000;
                end
            end
        end

        % Interpolate each age bin to annual resolution then replicate across locations
        % First column is always zero (no fertility below minimum age)
        fertilityRate = zeros(numLoc, numAgeF + 1, numT);
        for iA = 1:numAgeF
            birthsInterp = interp1(dataYears, birthMat(:,iA), demogYears, 'linear', 'extrap');
            birthsInterp = max(0, birthsInterp); % clamp - no negative fertility
            fertilityRate(:, iA + 1, :) = repmat(reshape(birthsInterp, 1,1,numT), numLoc,1,1);
        end

    else
        % --- STATIC (original behaviour): reshape to add a size-1 time dimension
        agePointsFertility = [fertilityTable.MinAge(1) (fertilityTable.MaxAge)'];
        staticFert = [zeros(height(locations),1) ones(height(locations),1) * (fertilityTable.Births)' / 1000];
        fertilityRate = reshape(staticFert, height(locations), length(agePointsFertility), 1);
    end
else
    agePointsFertility = [0 10 15 49 100];
    staticFert = rand(height(locations), length(agePointsFertility)) / 10;
    staticFert(:,[1 2 4 5]) = 0;
    fertilityRate = reshape(staticFert, height(locations), length(agePointsFertility), 1);
end

%any additional age-specific factors ought to be handled here
if(~isempty(modelParameters.agePreferencesFile))
    agePrefTable = readtable(modelParameters.agePreferencesFile);
    agePointsPref = (agePrefTable.MaxAge)';
    
    ageDiscountRateFactor = agePrefTable.discRateAge;
    
else
    agePointsPref = [0 100];
    ageDiscountRateFactor = [1 1];  %no change in discount rate with age
end
                                                                                                                                                                                                                                      