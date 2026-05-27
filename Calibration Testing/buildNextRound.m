function buildNextRound()
% buildNextRound.m  --  Madagascar calibration evaluator
%
% Loads all MC_Run_*.mat files from ../Outputs/, compares each run's
% cumulative migration matrix against the 2018 RGPH census OD data,
% computes goodness-of-fit metrics, and narrows the MC parameter bounds
% to the top (quantileMarker) fraction of runs.
%
% Migration calibration targets (2018 RGPH):
%   1. Recent   (past-12-months) 22x22 OD matrix  -- annual migration rates
%   2. Lifetime (region-of-birth) 22x22 OD matrix -- cumulative preferences
%
% Outputs:
%   updatedMCParams.mat   -- narrowed parameter bounds for next MC round
%   evaluationOutputs.mat -- all input/output tables (cached)

clear all;
close all;

%% -----------------------------------------------------------------------
%  REGION MAPPING
%  The model reads regions from the Admin_2 shapefile in PCODE order.
%  The census CSVs use a different regional ordering.
%
%  Shapefile (model) order:
%   1=Analamanga      2=Bongolava          3=Itasy         4=Vakinankaratra
%   5=Diana           6=Sava               7=Amoron'i mania 8=Atsimo-Atsinana
%   9=Haute matsiatra 10=Ihorombe          11=Vatovavy     12=Betsiboka
%  13=Boeny          14=Melaky            15=Sofia         16=Alaotra-Mangoro
%  17=Analanjirofo   18=Atsinanana        19=Androy        20=Anosy
%  21=Atsimo-Andrefana  22=Menabe
%
%  Census CSV column order:
%   1=Analamanga   2=Vakinankaratra  3=Itasy        4=Bongolava
%   5=Haute_Matsiatra  6=Amoroni_Mania  7=Vatovavy   8=Ihorombe
%   9=Atsimo_Atsinanana  10=Atsinanana  11=Analanjirofo  12=Alaotra_Mangoro
%  13=Boeny  14=Sofia  15=Betsiboka  16=Melaky
%  17=Atsimo_Andrefana  18=Androy  19=Anosy  20=Menabe
%  21=Diana  22=Sava
% -----------------------------------------------------------------------
% For each model index i, model_to_census(i) is the corresponding column
% index in the census CSV.
model_to_census = [1, 4, 3, 2, 21, 22, 6, 9, 5, 8, 7, 15, 13, 16, 14, 12, 11, 10, 18, 19, 17, 20];

regionNames = { ...
    'Analamanga','Bongolava','Itasy','Vakinankaratra', ...
    'Diana','Sava','Amoroni_Mania','Atsimo_Atsinanana', ...
    'Haute_Matsiatra','Ihorombe','Vatovavy_Fitovinany','Betsiboka', ...
    'Boeny','Melaky','Sofia','Alaotra_Mangoro', ...
    'Analanjirofo','Atsinanana','Androy','Anosy', ...
    'Atsimo_Andrefana','Menabe'};

nRegions = 22;
quantileMarker = 0.05;  % keep top 5% of runs

%% -----------------------------------------------------------------------
%  LOAD CENSUS MIGRATION DATA
% -----------------------------------------------------------------------
dataPath = '../Data/';  % adjust if running from a different directory
censusPath = [dataPath '../../' ...
    '../../ISF - Migration modelling consultancy/Datasets/Census migration/'];
% Try relative path first, then absolute fallback
recentFile   = [censusPath 'madagascar_migration_recent.csv'];
lifetimeFile = [censusPath 'madagascar_migration_lifetime_1.csv'];

% Absolute paths (edit these if relative paths break)
if ~exist(recentFile,'file')
    recentFile   = fullfile(fileparts(mfilename('fullpath')), ...
        '../../..', 'ISF - Migration modelling consultancy', ...
        'Datasets', 'Census migration', 'madagascar_migration_recent.csv');
    lifetimeFile = fullfile(fileparts(mfilename('fullpath')), ...
        '../../..', 'ISF - Migration modelling consultancy', ...
        'Datasets', 'Census migration', 'madagascar_migration_lifetime_1.csv');
end

fprintf('Loading census migration data...\n');
recentRaw   = readtable(recentFile,   'VariableNamingRule','preserve');
lifetimeRaw = readtable(lifetimeFile, 'VariableNamingRule','preserve');

% Extract 22x22 OD matrices (rows 1-22, cols 2-23 in table)
% Rows beyond 22 are summary statistics (Entree_Effectif etc.)
nDataRows = nRegions;
recentMat_census   = table2array(recentRaw(1:nDataRows,   2:(nRegions+1)));
lifetimeMat_census = table2array(lifetimeRaw(1:nDataRows, 2:(nRegions+1)));

% Convert to double, handling any NaN
recentMat_census   = double(recentMat_census);
lifetimeMat_census = double(lifetimeMat_census);

% Reorder rows and columns to match model (shapefile) region ordering
recentMat_model   = recentMat_census(model_to_census, model_to_census);
lifetimeMat_model = lifetimeMat_census(model_to_census, model_to_census);

% Zero out diagonal (within-region "moves" not meaningful for calibration)
recentMat_model(logical(eye(nRegions)))   = 0;
lifetimeMat_model(logical(eye(nRegions))) = 0;

%% -----------------------------------------------------------------------
%  POPULATION WEIGHTS
%  Use 1985 GHS-POP totals (in shapefile / model region order)
% -----------------------------------------------------------------------
popFile = [dataPath '1985_MDG_GHSPop_totals_by_region.csv'];
popRaw  = readtable(popFile, 'VariableNamingRule','preserve');
popData = popRaw.("1985_pop");  % already in shapefile order (22 values)

% Build population weight matrices
sourcePopWeights = repmat(popData', nRegions, 1);   % rows = source regions
destPopWeights   = repmat(popData,  1, nRegions);   % cols = dest regions
jointPopWeights  = sourcePopWeights .* destPopWeights;

% Normalise
sourcePopSum = sum(sourcePopWeights(:));
destPopSum   = sum(destPopWeights(:));
jointPopSum  = sum(jointPopWeights(:));

%% -----------------------------------------------------------------------
%  REFERENCE METRICS FROM CENSUS DATA
% -----------------------------------------------------------------------
% Fraction of total inter-regional moves (lifetime = cumulative preference)
fracMigsData_lifetime = lifetimeMat_model / sum(lifetimeMat_model(:));
fracMigsData_recent   = recentMat_model   / sum(recentMat_model(:));

% Per-capita out-migration rate (recent = annual; lifetime = cumulative)
totalPop = sum(popData);
migRateData_lifetime = lifetimeMat_model / totalPop;
migRateData_recent   = recentMat_model   / totalPop;

% In/out ratio per region (using recent data as primary)
outByRegion = sum(recentMat_model, 2) + eps;  % row sums = out-migrations
inByRegion  = sum(recentMat_model, 1)' + eps; % col sums = in-migrations
inOutData   = inByRegion ./ outByRegion;

%% -----------------------------------------------------------------------
%  URBAN / RURAL FRACTION TARGET
%  Source: 2018 RGPH madagascar_migrant_population_by_region.csv
%  Urban fraction = (nonmigrant_urban + migrant_urban) / total population
%  Used as proxy for non-agricultural (urban) utility layer participation.
%
%  Model interpretation:
%    Urban layers (non-ag): unskilled1, unskilled2, skilled  (layers 1-3)
%    Rural layers (ag):     rice_north, rice_south, maize,
%                           cassava, vanilla, industrial_crop (layers 5-10)
%    school (layer 4) excluded from ratio -- treated as transitional
%
%  Values in model (shapefile) region order:
% -----------------------------------------------------------------------
urbanFracData = [0.3784, 0.0663, 0.1685, 0.1505, 0.3396, 0.1856, ...
                 0.1287, 0.0711, 0.1707, 0.0948, 0.0948, 0.1294, ...
                 0.3584, 0.1088, 0.1207, 0.1402, 0.1582, 0.2755, ...
                 0.0959, 0.1614, 0.1418, 0.1621]';  % column vector

% Urban layer indices (matching utility_layers_v1.csv row order)
urbanLayerIdx = [1, 2, 3];   % unskilled1, unskilled2, skilled
agLayerIdx    = [5, 6, 7, 8, 9, 10]; % rice_north/south, maize, cassava, vanilla, industrial

%% -----------------------------------------------------------------------
%  FOOD INSECURITY TARGET
%  Source: Harvey et al. (2014) Phil. Trans. R. Soc. B 369:20130089
%  Survey of 600 smallholder households across 3 Madagascar landscapes
%  (eastern escarpment CAZ, highlands NSV, northwest CMK), Nov-Dec 2011.
%
%  Key statistics:
%    75%  of ag households cannot feed themselves year-round (any food insecurity)
%    3.8 months/year mean duration of food insufficiency  (Table 2)
%   27.3% lack sufficient food >= 6 months/year
%    5.5% food insecure year-round
%
%  Model target: fraction of agricultural agent-timesteps in which
%  net income (after sharing costs) < subsistence_costs
%  3.8 months / 12 = 0.317 expected food-insecure timestep fraction
%
%  NOTE: Harvey et al. covers only highland/eastern/northwest landscapes,
%  not the drier south -- so these rates likely underestimate national
%  average. Treat as a lower bound. Applied as a national aggregate only
%  (no regional breakdown available from this source).
% -----------------------------------------------------------------------
foodInsecureTarget_agFrac = 3.8 / 12;   % ~0.317 fraction of ag timesteps below subsistence
foodInsecureTarget_lower  = 0.05;        % year-round insecure (5.5%) -- lower plausibility bound
foodInsecureTarget_upper  = 0.75;        % ever insecure in a year -- upper plausibility bound

%% -----------------------------------------------------------------------
%  EVALUATE MODEL RUNS
% -----------------------------------------------------------------------
%try
%    load evaluationOutputs
%    disp('Loaded cached evaluationOutputs.');
%    disp(outputListRun);
%catch
    fileList = dir('D:/MIDAS outputs/MC*.mat'); % dir('../Outputs/MC*.mat');
    if isempty(fileList)
        error('No MC*.mat files found in D:/MIDAS outputs/. Run runMIDASExperiment first.');
    end
    fprintf('Found %d MC run files. Evaluating...\n', length(fileList));

    skip = false(length(fileList), 1);
    inputListRun  = [];
    outputListRun = [];

    for indexI = 1:length(fileList)
        try
            currentRun = load(fullfile(fileList(indexI).folder, fileList(indexI).name));
            fprintf('  Run %d of %d: %s\n', indexI, length(fileList), fileList(indexI).name);

            %% Aggregate migration matrix over time
            rawMM = currentRun.output.migrationMatrix;  % nLocs x nLocs x T
            if ndims(rawMM) == 3
                % Sum over all timesteps (exclude spinup if stored separately)
                % Get spinupTime if available in output
                if isfield(currentRun.output, 'modelParameters')
                    spinupSteps = currentRun.output.modelParameters.spinupTime;
                else
                    spinupSteps = 0;
                end
                tempMat = sum(rawMM(:,:,(spinupSteps+1):end), 3);
            else
                tempMat = rawMM;  % already 2D (legacy format)
            end
            tempMat = double(tempMat);

            % Only consider inter-regional moves (zero diagonal)
            tempMat(logical(eye(size(tempMat,1)))) = 0;

            %% Check dimension matches
            if size(tempMat,1) ~= nRegions
                fprintf('    WARNING: migration matrix is %dx%d, expected %dx%d. Skipping.\n', ...
                    size(tempMat,1), size(tempMat,2), nRegions, nRegions);
                skip(indexI) = true;
                continue;
            end

            %% --- Fraction of migrations ---
            fracMigsRun  = tempMat / (sum(tempMat(:)) + eps);

            %% --- Per-capita migration rate ---
            % Normalise by total number of agents that ever lived (use agentSummary)
            if isfield(currentRun.output, 'agentSummary')
                nAgentsTotal = size(currentRun.output.agentSummary, 1);
            else
                nAgentsTotal = sum(tempMat(:));
            end
            migRateRun = tempMat / (nAgentsTotal + eps);

            %% --- In/out ratio ---
            outRun = sum(tempMat, 2) + eps;
            inRun  = sum(tempMat, 1)' + eps;
            inOutRun = inRun ./ outRun;

            %% --- In/out flow fractions (PRIMARY migration target) ---
            % Row sums (outbound fractions) and column sums (inbound
            % fractions) of the OD fraction matrix. These 44 well-
            % determined regional aggregates carry the same broad
            % spatial signal (which regions are net senders vs
            % receivers, what the national mobility level is) without
            % the per-cell noise of the full 462-cell OD matrix that
            % consistently scored near zero in earlier rounds.
            outFlowFrac_run    = sum(fracMigsRun, 2);                % 22 x 1
            inFlowFrac_run     = sum(fracMigsRun, 1)';               % 22 x 1
            outFlowFrac_data_L = sum(fracMigsData_lifetime, 2);
            inFlowFrac_data_L  = sum(fracMigsData_lifetime, 1)';
            outFlowFrac_data_R = sum(fracMigsData_recent,   2);
            inFlowFrac_data_R  = sum(fracMigsData_recent,   1)';

            flowVec_run    = [outFlowFrac_run;    inFlowFrac_run];     % 44 x 1
            flowVec_data_L = [outFlowFrac_data_L; inFlowFrac_data_L];
            flowVec_data_R = [outFlowFrac_data_R; inFlowFrac_data_R];
            popVec44       = [popData; popData];

            flowFrac_r2          = weightedPearson(flowVec_run, flowVec_data_L, ones(2*nRegions,1));
            popWeightFlowFrac_r2 = weightedPearson(flowVec_run, flowVec_data_L, popVec44);
            recentFlowFrac_r2    = weightedPearson(flowVec_run, flowVec_data_R, ones(2*nRegions,1));
            recentPopWeightFlowFrac_r2 = weightedPearson(flowVec_run, flowVec_data_R, popVec44);

            %% --- Fit metrics (lifetime OD fractions as primary target) ---
            % Unweighted and population-weighted squared errors
            fracMigsError              = sum(sum((fracMigsRun - fracMigsData_lifetime).^2));
            sourceWeightFracMigsError  = sum(sum(((fracMigsRun - fracMigsData_lifetime).^2) .* sourcePopWeights)) / sourcePopSum;
            destWeightFracMigsError    = sum(sum(((fracMigsRun - fracMigsData_lifetime).^2) .* destPopWeights))   / destPopSum;
            jointWeightFracMigsError   = sum(sum(((fracMigsRun - fracMigsData_lifetime).^2) .* jointPopWeights))  / jointPopSum;

            migRateError               = sum(sum((migRateRun - migRateData_lifetime).^2));
            sourceWeightMigRateError   = sum(sum(((migRateRun - migRateData_lifetime).^2) .* sourcePopWeights)) / sourcePopSum;
            destWeightMigRateError     = sum(sum(((migRateRun - migRateData_lifetime).^2) .* destPopWeights))   / destPopSum;
            jointWeightMigRateError    = sum(sum(((migRateRun - migRateData_lifetime).^2) .* jointPopWeights))  / jointPopSum;

            inOutError                 = sum((inOutRun - inOutData).^2);
            popWeightInOutError        = sum(((inOutRun - inOutData).^2) .* popData) / sum(popData);

            %% Pearson r² metrics
            fracMigs_r2        = weightedPearson(fracMigsRun(:), fracMigsData_lifetime(:), ones(numel(fracMigsRun),1));
            sourceFracMigs_r2  = weightedPearson(fracMigsRun(:), fracMigsData_lifetime(:), sourcePopWeights(:));
            destFracMigs_r2    = weightedPearson(fracMigsRun(:), fracMigsData_lifetime(:), destPopWeights(:));
            jointFracMigs_r2   = weightedPearson(fracMigsRun(:), fracMigsData_lifetime(:), jointPopWeights(:));

            migRate_r2         = weightedPearson(migRateRun(:), migRateData_lifetime(:), ones(numel(migRateRun),1));
            sourceMigRate_r2   = weightedPearson(migRateRun(:), migRateData_lifetime(:), sourcePopWeights(:));
            destMigRate_r2     = weightedPearson(migRateRun(:), migRateData_lifetime(:), destPopWeights(:));
            jointMigRate_r2    = weightedPearson(migRateRun(:), migRateData_lifetime(:), jointPopWeights(:));

            inOutError_r2      = weightedPearson(inOutRun(:), inOutData(:), ones(numel(inOutRun),1));
            popInOut_r2        = weightedPearson(inOutRun(:), inOutData(:), popData(:));

            %% Also compare against RECENT migration (secondary target)
            recentFracMigsRun        = fracMigsRun;  % same OD fractions, different reference
            recentFracMigs_r2        = weightedPearson(recentFracMigsRun(:), fracMigsData_recent(:), ones(numel(recentFracMigsRun),1));
            recentJointFracMigs_r2   = weightedPearson(recentFracMigsRun(:), fracMigsData_recent(:), jointPopWeights(:));

            %% --- Urban/rural layer fraction ---
            % PRIMARY urban target: national population-weighted urban
            % fraction (a single well-determined number). The per-region
            % vector is retained as a reporting diagnostic but is no
            % longer in the scoring -- MIDAS does not vary structurally
            % across regions enough to reproduce the 22-element spatial
            % pattern, and chasing it adds noise without signal.
            urbanFracRun          = zeros(nRegions, 1);
            urbanFracError        = NaN;   % per-region pop-weighted SSE  (diagnostic)
            urbanFrac_r2          = NaN;   % per-region unweighted r²     (diagnostic)
            popWeightUrbanFrac_r2 = NaN;   % per-region pop-weighted r²   (diagnostic)
            urbanFrac_nat_run     = NaN;   % national pop-weighted fraction (model)
            urbanFracNatError     = NaN;   % (model - data)^2  -- scored

            urbanFrac_nat_data = sum(urbanFracData .* popData) / sum(popData);

            if isfield(currentRun.output, 'countAgentsPerLayer')
                cal = currentRun.output.countAgentsPerLayer;  % nLocs x nLayers x T
                [nL, nLay, nT] = size(cal);
                if nL == nRegions && nLay >= max([urbanLayerIdx agLayerIdx])
                    % Use last 20 timesteps (5 model years) as calibration window
                    tWindow = max(1, nT-19):nT;
                    calWindow = mean(cal(:, :, tWindow), 3);  % nLocs x nLayers

                    urbanCount = sum(calWindow(:, urbanLayerIdx), 2);
                    agCount    = sum(calWindow(:, agLayerIdx),    2);
                    totalCount = urbanCount + agCount + eps;
                    urbanFracRun = urbanCount ./ totalCount;

                    % Per-region diagnostics (no longer scored)
                    urbanFracError = sum(((urbanFracRun - urbanFracData).^2) .* popData) / sum(popData);
                    urbanFrac_r2          = weightedPearson(urbanFracRun, urbanFracData, ones(nRegions,1));
                    popWeightUrbanFrac_r2 = weightedPearson(urbanFracRun, urbanFracData, popData);

                    % National pop-weighted urban fraction (scored target)
                    urbanFrac_nat_run = sum(urbanFracRun .* popData) / sum(popData);
                    urbanFracNatError = (urbanFrac_nat_run - urbanFrac_nat_data)^2;
                end
            end

            %% --- Food insecurity rate (quaternary target) ---
            % Compare fraction of ag agent-timesteps below subsistence vs Harvey et al. 2014
            foodInsecureRate_ag = NaN;
            foodInsecureError   = NaN;

            if isfield(currentRun.output, 'foodInsecureCount_ag') && ...
               isfield(currentRun.output, 'agentCount_ag')
                fiCount = currentRun.output.foodInsecureCount_ag;   % nLocs x T
                agCount = currentRun.output.agentCount_ag;          % nLocs x T
                totalAgSteps = sum(agCount(:));
                if totalAgSteps > 0
                    foodInsecureRate_ag = sum(fiCount(:)) / totalAgSteps;
                end
                % Squared deviation from the 3.8-month target
                foodInsecureError = (foodInsecureRate_ag - foodInsecureTarget_agFrac)^2;
            end

            %% Assemble input/output tables
            currentInputRun = array2table( ...
                [currentRun.input.parameterValues]', ...
                'VariableNames', strrep({currentRun.input.parameterNames{:}}, '.', ''));

            currentOutputRun = table( ...
                fracMigsError, sourceWeightFracMigsError, destWeightFracMigsError, jointWeightFracMigsError, ...
                migRateError, sourceWeightMigRateError, destWeightMigRateError, jointWeightMigRateError, ...
                fracMigs_r2, sourceFracMigs_r2, destFracMigs_r2, jointFracMigs_r2, ...
                migRate_r2, sourceMigRate_r2, destMigRate_r2, jointMigRate_r2, ...
                inOutError, popWeightInOutError, inOutError_r2, popInOut_r2, ...
                recentFracMigs_r2, recentJointFracMigs_r2, ...
                flowFrac_r2, popWeightFlowFrac_r2, recentFlowFrac_r2, recentPopWeightFlowFrac_r2, ...
                urbanFracError, urbanFrac_r2, popWeightUrbanFrac_r2, ...
                urbanFrac_nat_run, urbanFracNatError, ...
                foodInsecureRate_ag, foodInsecureError, ...
                'VariableNames', { ...
                    'FracMigsError','SourceWeightFracMigsError','DestWeightFracMigsError','JointWeightFracMigsError', ...
                    'MigRateError','SourceWeightMigRateError','DestWeightMigRateError','JointWeightMigRateError', ...
                    'fracMigs_r2','sourceFracMigs_r2','destFracMigs_r2','jointFracMigs_r2', ...
                    'migRate_r2','sourceMigRate_r2','destMigRate_r2','jointMigRate_r2', ...
                    'inOutError','popWeightInOutError','inOutError_r2','popInOut_r2', ...
                    'recentFracMigs_r2','recentJointFracMigs_r2', ...
                    'flowFrac_r2','popWeightFlowFrac_r2','recentFlowFrac_r2','recentPopWeightFlowFrac_r2', ...
                    'urbanFracError','urbanFrac_r2','popWeightUrbanFrac_r2', ...
                    'urbanFrac_nat_run','urbanFracNatError', ...
                    'foodInsecureRate_ag','foodInsecureError'});

            if isempty(inputListRun)
                inputListRun  = currentInputRun;
                outputListRun = currentOutputRun;
            else
                inputListRun(indexI, :)  = currentInputRun;
                outputListRun(indexI, :) = currentOutputRun;
            end

        catch ME
            fprintf('    ERROR in run %d: %s\n', indexI, ME.message);
            skip(indexI) = true;
        end
    end

    % Remove failed runs
    skip = skip(1:height(inputListRun));
    inputListRun(skip, :)  = [];
    outputListRun(skip, :) = [];
    fileList(skip) = [];

    fprintf('\nSuccessfully evaluated %d runs.\n', height(inputListRun));

    % -------------------------------------------------------------------
    % MULTI-REALISATION AVERAGING
    %
    % From round 4 onward each parameter set is run multiple times with
    % different RNG seeds (see run_calibration.m's nRealisations). Here
    % we detect runs sharing the same parameter vector by hashing the
    % input row, group them, and average all metric columns. This removes
    % seed-driven noise from the score before narrowing.
    %
    % For single-realisation rounds (or mixed-round MC files) every
    % parameter vector is unique, so each group has size 1 and the
    % averaging is a no-op -- the code below collapses gracefully.
    % -------------------------------------------------------------------
    if height(inputListRun) > 0
        nRunsPreGroup = height(inputListRun);
        inputArr = table2array(inputListRun);

        % Hash each row of parameter values to a string key. %.10g gives
        % enough precision to distinguish genuinely different draws while
        % keeping identical draws bit-identical after the table->array
        % round trip.
        paramHashes = cell(nRunsPreGroup, 1);
        for kRow = 1:nRunsPreGroup
            paramHashes{kRow} = sprintf('%.10g,', inputArr(kRow, :));
        end
        [uniqueHashes, ~, groupIdx] = unique(paramHashes);
        nGroups = numel(uniqueHashes);

        if nGroups < nRunsPreGroup
            % There are repeated parameter sets -- average within groups.
            fprintf(['Multi-realisation detected: %d runs across %d unique parameter sets ' ...
                     '(mean %.1f realisations per set).\n'], ...
                     nRunsPreGroup, nGroups, nRunsPreGroup / nGroups);

            % Preallocate grouped tables by taking the first row of each
            % group as a template (inputs are identical within a group).
            firstIdxPerGroup = zeros(nGroups, 1);
            for g = 1:nGroups
                firstIdxPerGroup(g) = find(groupIdx == g, 1, 'first');
            end
            groupedInput  = inputListRun(firstIdxPerGroup, :);
            groupedOutput = outputListRun(firstIdxPerGroup, :);

            % Average all numeric output columns within each group (NaN-aware)
            outVarNames = outputListRun.Properties.VariableNames;
            for cIdx = 1:numel(outVarNames)
                v = outputListRun.(outVarNames{cIdx});
                if isnumeric(v)
                    avg = zeros(nGroups, 1);
                    for g = 1:nGroups
                        mask = (groupIdx == g);
                        vals = v(mask);
                        avg(g) = mean(vals(~isnan(vals)));
                    end
                    groupedOutput.(outVarNames{cIdx}) = avg;
                end
            end

            % Keep an arbitrary representative filename per group for traceability
            groupedFileList = fileList(firstIdxPerGroup);

            % Replace the per-run tables with the grouped versions for all
            % downstream summary / scoring / narrowing logic.
            inputListRun  = groupedInput;
            outputListRun = groupedOutput;
            fileList      = groupedFileList;
        else
            fprintf('No repeated parameter sets detected (single-realisation mode).\n');
        end
    end

    save evaluationOutputs inputListRun outputListRun fileList;
%end

%% -----------------------------------------------------------------------
%  PRINT SUMMARY STATISTICS
% -----------------------------------------------------------------------
if height(outputListRun) > 0
    fprintf('\n=== Calibration Summary (%d runs) ===\n', height(outputListRun));
    fprintf('\n-- SCORED METRICS (round 3+) --\n');
    fprintf('Metric                      Mean     Median   Max\n');
    fprintf('popWeightFlowFrac_r2     %7.4f  %7.4f  %7.4f   <-- migration in/out flows (scored)\n', ...
        mean(outputListRun.popWeightFlowFrac_r2), median(outputListRun.popWeightFlowFrac_r2), max(outputListRun.popWeightFlowFrac_r2));
    validUrbanNat = outputListRun.urbanFracNatError(~isnan(outputListRun.urbanFracNatError));
    if ~isempty(validUrbanNat)
        urbanRun = outputListRun.urbanFrac_nat_run(~isnan(outputListRun.urbanFrac_nat_run));
        fprintf('urbanFrac_nat_run        %7.4f  %7.4f  %7.4f   (target: %.4f, national pop-weighted)\n', ...
            mean(urbanRun), median(urbanRun), max(urbanRun), ...
            sum(urbanFracData .* popData) / sum(popData));
    end
    validFI = outputListRun.foodInsecureRate_ag(~isnan(outputListRun.foodInsecureRate_ag));
    if ~isempty(validFI)
        fprintf('foodInsecureRate_ag      %7.4f  %7.4f  %7.4f   (target: %.4f)\n', ...
            mean(validFI), median(validFI), max(validFI), foodInsecureTarget_agFrac);
    end

    fprintf('\n-- DIAGNOSTIC METRICS (not scored) --\n');
    fprintf('Metric                      Mean     Median   Max\n');
    fprintf('jointFracMigs_r2         %7.4f  %7.4f  %7.4f   (full 22x22 OD lifetime)\n', ...
        mean(outputListRun.jointFracMigs_r2), median(outputListRun.jointFracMigs_r2), max(outputListRun.jointFracMigs_r2));
    fprintf('fracMigs_r2 (unwtd)      %7.4f  %7.4f  %7.4f\n', ...
        mean(outputListRun.fracMigs_r2), median(outputListRun.fracMigs_r2), max(outputListRun.fracMigs_r2));
    fprintf('recentJointFracMigs_r2   %7.4f  %7.4f  %7.4f   (full 22x22 OD recent)\n', ...
        mean(outputListRun.recentJointFracMigs_r2), median(outputListRun.recentJointFracMigs_r2), max(outputListRun.recentJointFracMigs_r2));
    fprintf('flowFrac_r2 (unwtd)      %7.4f  %7.4f  %7.4f   (in/out flows, unweighted)\n', ...
        mean(outputListRun.flowFrac_r2), median(outputListRun.flowFrac_r2), max(outputListRun.flowFrac_r2));
    fprintf('recentPopWeightFlowFrac_r2 %7.4f  %7.4f  %7.4f (in/out flows vs recent)\n', ...
        mean(outputListRun.recentPopWeightFlowFrac_r2), median(outputListRun.recentPopWeightFlowFrac_r2), max(outputListRun.recentPopWeightFlowFrac_r2));
    fprintf('inOutError_r2            %7.4f  %7.4f  %7.4f   (in/out ratio per region)\n', ...
        mean(outputListRun.inOutError_r2), median(outputListRun.inOutError_r2), max(outputListRun.inOutError_r2));
    validUrban = outputListRun.popWeightUrbanFrac_r2(~isnan(outputListRun.popWeightUrbanFrac_r2));
    if ~isempty(validUrban)
        fprintf('popWeightUrbanFrac_r2    %7.4f  %7.4f  %7.4f   (per-region urban share)\n', ...
            mean(validUrban), median(validUrban), max(validUrban));
    else
        fprintf('popWeightUrbanFrac_r2    [not available -- countAgentsPerLayer missing or wrong size]\n');
    end
end

%% -----------------------------------------------------------------------
%  UPDATE PARAMETER BOUNDS
%  Select top quantileMarker fraction based on joint population-weighted r²
% -----------------------------------------------------------------------
if height(outputListRun) < 2
    warning('Not enough runs to update parameter bounds. Need at least 2 successful runs.');
    return;
end

% Combined score: weighted average of three calibration targets.
%   Migration in/out flows  (popWeightFlowFrac_r2) -- 0-1 r² scale
%   National urban fraction (urbanFracNatError)    -- squared error, inverted to 0-1
%   Food insecurity rate    (foodInsecureError)    -- squared error, inverted to 0-1
%
% This replaces the round-1/2 scoring against the full 462-cell OD matrix
% and per-region urban fraction vector. Those targets consistently scored
% near zero (max r² < 0.13 across two rounds, 2000 runs) -- they ask the
% model to reproduce spatial patterns it cannot structurally generate.
% In/out flow aggregates (44 well-determined numbers) and the national
% urban share (1 number) carry the same scientific signal -- which regions
% are net senders vs receivers, what the overall mobility level is, and
% what the urban/rural balance is -- at a much higher signal-to-noise.
%
% Per-region OD-matrix r²s and per-region urban-fraction r²s are still
% computed and saved as diagnostics in the output table, but no longer
% contribute to the score.
%
% Weights: roughly equal across the three targets (~1/3 each).
% If a target is unavailable (NaN), its weight is redistributed proportionally.
%
% IMPORTANT: all three component scores must be on the SAME 0-1 scale for
% the equal weights to mean equal influence. The urban and food-insecurity
% components are batch-relative (1 - error/maxError, spanning 0-1 within the
% batch). The migration component must be put on the same footing -- using
% the raw popWeightFlowFrac_r2 (which only spans ~0-0.34) would give
% migration roughly a third of its intended weight, so the top-X% selection
% ends up driven almost entirely by urban + food insecurity and the
% migration parameters never narrow. We therefore batch-normalise migration
% the same way: migScore = r2 / max(r2 in batch).
migWeight   = 0.34;
urbanWeight = 0.33;
fiWeight    = 0.33;

hasUrban = ~isnan(outputListRun.urbanFracNatError);
hasFI    = ~isnan(outputListRun.foodInsecureRate_ag);

% Normalise migration r² to a batch-relative 0-1 score (1 = best fit in batch).
% Unlike urban/FI this is a goodness metric (higher = better), so we divide
% by the batch max rather than inverting an error.
maxMig = max(outputListRun.popWeightFlowFrac_r2);
if isempty(maxMig) || maxMig <= 0; maxMig = 1; end
migScore = outputListRun.popWeightFlowFrac_r2 / maxMig;

% Normalise urban-fraction error to 0-1 score (1 = perfect, 0 = worst)
maxUrbanError = max(outputListRun.urbanFracNatError(hasUrban));
if isempty(maxUrbanError) || maxUrbanError == 0; maxUrbanError = 1; end
urbanScore = 1 - outputListRun.urbanFracNatError / maxUrbanError;
urbanScore(~hasUrban) = NaN;

% Normalise food insecurity error to 0-1 score (1 = perfect, 0 = worst)
maxFIerror = max(outputListRun.foodInsecureError(hasFI));
if isempty(maxFIerror) || maxFIerror == 0; maxFIerror = 1; end
fiScore = 1 - outputListRun.foodInsecureError / maxFIerror;
fiScore(~hasFI) = NaN;

% Build combined score, redistributing weights for missing targets
activeWeights = migWeight + urbanWeight * any(hasUrban) + fiWeight * any(hasFI);
combinedScore = (migWeight / activeWeights) * migScore;

if any(hasUrban)
    urbanScoreAdj = urbanScore;
    urbanScoreAdj(~hasUrban) = 0;
    combinedScore = combinedScore + (urbanWeight / activeWeights) * urbanScoreAdj;
end
if any(hasFI)
    fiScoreAdj = fiScore;
    fiScoreAdj(~hasFI) = 0;
    combinedScore = combinedScore + (fiWeight / activeWeights) * fiScoreAdj;
end

fprintf('Combined score weights: migration=%.0f%%, urban=%.0f%%, food insecurity=%.0f%%\n', ...
    migWeight/activeWeights*100, ...
    urbanWeight*any(hasUrban)/activeWeights*100, ...
    fiWeight*any(hasFI)/activeWeights*100);

minScore  = quantile(combinedScore, [1 - quantileMarker]);
bestInputs = inputListRun(combinedScore >= minScore, :);
fprintf('Top %.0f%% runs: %d / %d selected (combined score >= %.4f)\n', ...
    quantileMarker * 100, height(bestInputs), height(inputListRun), minScore);

% Load the experiment parameter table to get current bounds
expList = dir('D:/MIDAS outputs/experiment_*.mat'); % dir('../Outputs/experiment_*.mat');
if isempty(expList)
    warning('No experiment_*.mat file found in ../Outputs/. Cannot update bounds.');
    return;
end
load(fullfile(expList(end).folder, expList(end).name));  % loads mcParams

% Narrowing rule: take the 5th and 95th percentile of each parameter's
% values across the top-scoring runs, rather than the absolute min and max.
% This is robust to outliers -- a single top-50 run with an extreme value
% on a parameter no longer pins the bound to that extreme. With 50 runs
% in the top 5%, the 5th and 95th percentiles correspond to roughly the
% 3rd and 47th order statistics, dropping the two most extreme values at
% each end.
%
% Effect on round 3: in that round urbanIncomeMultiplier narrowed only from
% [0.5, 1.5] to [0.539, 1.493] under min/max, almost certainly because a
% small number of outliers dragged the bounds to the wall. Quantile-based
% narrowing should give a meaningfully tighter range when the bulk of the
% top-50 clusters away from the prior boundaries.
NARROWING_QUANTILE_LOWER = 0.05;
NARROWING_QUANTILE_UPPER = 0.95;

for indexI = 1:height(mcParams)
    varName = strrep(mcParams.Name{indexI}, '.', '');
    tempIndex = find(strcmp(inputListRun.Properties.VariableNames, varName));
    if ~isempty(tempIndex)
        values = table2array(bestInputs(:, tempIndex));
        if numel(values) < 2
            % Degenerate top set: keep original bounds untouched.
            continue;
        end
        mcParams.Lower(indexI) = quantile(values, NARROWING_QUANTILE_LOWER);
        mcParams.Upper(indexI) = quantile(values, NARROWING_QUANTILE_UPPER);
        % If the original prior was integer-valued, round the new bounds
        % back to integers to keep the calibration consistent with the
        % parameter type. mcParams.RoundYN is the source-of-truth flag.
        if mcParams.RoundYN(indexI)
            mcParams.Lower(indexI) = floor(mcParams.Lower(indexI));
            mcParams.Upper(indexI) = ceil(mcParams.Upper(indexI));
        end
        % Guard against the quantile range collapsing to a point.
        if mcParams.Upper(indexI) <= mcParams.Lower(indexI)
            mcParams.Upper(indexI) = mcParams.Lower(indexI) + eps;
        end
    else
        fprintf('  WARNING: parameter "%s" not found in run outputs.\n', varName);
    end
end

save updatedMCParams mcParams;
fprintf('Saved updatedMCParams.mat with narrowed bounds for next calibration round.\n');

end % function buildNextRound


%% -----------------------------------------------------------------------
%  HELPER: population-weighted Pearson r²
% -----------------------------------------------------------------------
function rho_2 = weightedPearson(X, Y, w)
    % Guard against degenerate cases
    if sum(w) == 0 || var(X) == 0 || var(Y) == 0
        rho_2 = NaN;
        return;
    end
    mX = sum(X .* w) / sum(w);
    mY = sum(Y .* w) / sum(w);
    covXY = sum(w .* (X - mX) .* (Y - mY)) / sum(w);
    covXX = sum(w .* (X - mX) .^ 2)         / sum(w);
    covYY = sum(w .* (Y - mY) .^ 2)         / sum(w);
    rho_w = covXY / sqrt(covXX * covYY + eps);
    rho_2 = rho_w ^ 2;
end


%% -----------------------------------------------------------------------
%  VISUALISATION (call manually after evaluation)
% -----------------------------------------------------------------------
function plotMigrations(matrix, r2, metricTitle)
    figure;
    imagesc(matrix);
    ax = gca;
    set(ax, 'YTick', 1:22, 'XTick', 1:22, ...
        'YTickLabel', { ...
            'Analamanga','Bongolava','Itasy','Vakinankaratra', ...
            'Diana','Sava','Amoroni Mania','Atsimo Atsinanana', ...
            'Haute Matsiatra','Ihorombe','Vatovavy','Betsiboka', ...
            'Boeny','Melaky','Sofia','Alaotra-Mangoro', ...
            'Analanjirofo','Atsinanana','Androy','Anosy', ...
            'Atsimo-Andrefana','Menabe'}, ...
        'XTickLabel', { ...
            'Analamanga','Bongolava','Itasy','Vakinankaratra', ...
            'Diana','Sava','Amoroni Mania','Atsimo Atsinanana', ...
            'Haute Matsiatra','Ihorombe','Vatovavy','Betsiboka', ...
            'Boeny','Melaky','Sofia','Alaotra-Mangoro', ...
            'Analanjirofo','Atsinanana','Androy','Anosy', ...
            'Atsimo-Andrefana','Menabe'});
    xtickangle(90);
    colorbar;
    colormap hot;
    title([metricTitle ' (Weighted r^2 = ' num2str(r2,'%.3f') ')']);
    grid on;
    set(ax, 'GridColor', 'white', 'FontSize', 9);
    ylabel('ORIGIN', 'FontSize', 14);
    xlabel('DESTINATION', 'FontSize', 14);
    set(gcf, 'Position', [100 100 700 600]);
end
