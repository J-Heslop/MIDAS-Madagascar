function runMIDASExperiment_parallel(nWorkers, taskId, drawsPerTask, nRealisations, distressArm, expectationArm)
% runMIDASExperiment_parallel  --  parfor-enabled calibration runner
%
% Identical to runMIDASExperiment but uses parfor instead of for.
% Call this from the SLURM script after opening a parpool.
%
% Usage (single-shot, e.g. interactive):
%   runMIDASExperiment_parallel(20);            % defaults: 200 single-realisation runs
%
% Usage (SLURM array task with multi-realisation, called from run_calibration.m):
%   runMIDASExperiment_parallel(20, taskId, drawsPerTask, nRealisations);
%
% Inputs:
%   nWorkers       - workers in parpool (informational; pool may already be open)
%   taskId         - SLURM_ARRAY_TASK_ID (0 = non-array single-shot run)
%   drawsPerTask   - number of UNIQUE parameter draws this task will sample
%   nRealisations  - number of seed replications per draw (1 = single-realisation,
%                    3 = three different RNG seeds per draw for noise averaging)
%
% Total runs this task performs = drawsPerTask * nRealisations.
%
% Multi-realisation rationale: each parameter set is run nRealisations times
% with different RNG seeds. buildNextRound.m groups runs by parameter vector
% and averages their fit metrics before scoring, so seed-driven noise in any
% single run cancels out and the score reflects the parameter set's true
% performance rather than RNG luck.
%
% RNG seeding (deterministic per task / draw / realisation):
%   rng( taskId * 10000 + drawIdx * 10 + realisationIdx )
% This guarantees disjoint, reproducible streams across the array.
%
% File tagging:
%   Outputs/MC_Run_T<task>_D<draw>_R<realisation>_<date>.mat   (multi-realisation)
%   Outputs/MC_Run_T<task>_<run>_<date>.mat                    (single-realisation, legacy)

if nargin < 1 || isempty(nWorkers);      nWorkers      = 20;  end
if nargin < 2 || isempty(taskId);        taskId        = 0;   end
if nargin < 3 || isempty(drawsPerTask);  drawsPerTask  = 200; end
if nargin < 4 || isempty(nRealisations); nRealisations = 1;   end
if nargin < 5 || isempty(distressArm);   distressArm   = 0;   end
if nargin < 6 || isempty(expectationArm); expectationArm = 0;  end
% distressArm: 0=OVERLAY OFF (true baseline), 1=Variant A (FI counter),
% 2=Variant B (wealth+duration), 3=Variant C (cumulative shortfall),
% 4=Variant D (stochastic depth), 5=Variant E (income shock vs own
% trailing mean -- conditions on the income link of the chain, which the
% chain audit showed is the last link carrying a drought signal),
% 6=Variant F (income shock AND depleted livestock buffer; auto-enables
% the buffer).
% expectationArm: 0=baseline (current MIDAS), 1=adaptive expectations,
% 2=windowed sampling, 3=naive forecast, 4=adaptive+shocks.
% Combined they select the active trigger/expectation logic AND the
% output subfolder. See checkDistressTrigger.m and formExpectation.m.
%
% NB: the default used to be 1 (Variant A) and the overlay-enable flag was
% appended with bounds [1, 1] UNCONDITIONALLY, so every run through this
% script -- including intended baselines and all expectation-arm runs --
% had the Variant A overlay active. Default is now 0 = genuinely off.
if ~ismember(distressArm, [0 1 2 3 4 5 6])
    error('runMIDASExperiment_parallel:badArm', ...
          'distressArm must be 0 (off) or 1-6; got %g', distressArm);
end
if ~ismember(expectationArm, [0 1 2 3 4])
    error('runMIDASExperiment_parallel:badExpectationArm', ...
          'expectationArm must be 0-4; got %g', expectationArm);
end

modelRuns = drawsPerTask * nRealisations;   % total parfor iterations

% Add paths FIRST so workers inherit them when the pool starts
addpath('./Override_Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');
addpath('./Core_MIDAS_Code');

% Open or reuse a parallel pool. Doing this AFTER addpath ensures workers
% inherit the project paths (parpool snapshots the client path at startup).
%
% CRITICAL for SLURM array jobs: give each array task its OWN
% JobStorageLocation. The 'local' profile defaults to a SHARED directory
% under ~/.matlab/local_cluster_jobs, so when many array tasks open pools
% concurrently they corrupt each other's pool metadata -- which can abort
% the pool launch and (when the task is then killed) leaves empty logs.
% Pointing each task at a unique, node-local scratch dir eliminates the
% collision. Falls back gracefully to tempdir when not in an array.
existingPool = gcp('nocreate');
if isempty(existingPool)
    pc = parcluster('local');

    tmpRoot = getenv('TMPDIR');
    if isempty(tmpRoot); tmpRoot = tempdir; end
    aJob  = getenv('SLURM_ARRAY_JOB_ID');
    aTask = getenv('SLURM_ARRAY_TASK_ID');
    if isempty(aJob);  aJob  = num2str(feature('getpid')); end
    if isempty(aTask); aTask = '0'; end
    jobDir = fullfile(tmpRoot, sprintf('midas_pool_%s_%s', aJob, aTask));
    if ~exist(jobDir, 'dir'); mkdir(jobDir); end
    pc.JobStorageLocation = jobDir;

    fprintf('Opening parallel pool with %d workers (JobStorageLocation = %s)...\n', ...
            nWorkers, jobDir);
    parpool(pc, nWorkers);
elseif existingPool.NumWorkers ~= nWorkers
    fprintf('Existing parpool has %d workers (requested %d) - reusing.\n', ...
            existingPool.NumWorkers, nWorkers);
end

% Belt-and-braces: explicitly push the addpaths to all workers in case
% AutoAddClientPath is disabled in this cluster profile.
rootDir = pwd;
parfevalOnAll(@addpath, 0, ...
    fullfile(rootDir,'Override_Core_MIDAS_Code'), ...
    fullfile(rootDir,'Application_Specific_MIDAS_Code'), ...
    fullfile(rootDir,'Core_MIDAS_Code'));

% Seed deterministically from taskId when running as a SLURM array task,
% so that (a) each task draws a disjoint chunk of the parameter space and
% (b) failed tasks can be re-run and reproduce their original draws.
% Single-shot runs (taskId == 0) keep the original 'shuffle' behaviour.
if taskId > 0
    rng(taskId);
    fprintf('RNG seeded with taskId=%d (deterministic).\n', taskId);
else
    rng('shuffle');
    fprintf('RNG seeded with ''shuffle'' (non-deterministic).\n');
end

outputList = {};
series = 'MC_Run_';
% Arm-aware output folder so concurrent arm submissions don't collide.
% For pure-baseline (no overlay, no expectation variant) the folder is
% ./Outputs/. Distress overlay arms 2-4 land in ./Outputs_Arm<N>/.
% Expectation arms 1-4 (with distress disabled or default) land in
% ./Outputs_ExpArm<N>/. If both an overlay and an expectation arm are
% active simultaneously, the combined folder name is used.
folderParts = {};
if distressArm ~= 0
    % Every ACTIVE distress arm gets its own suffix, including Variant A
    % (previously arm 1 wrote to the baseline folder ./Outputs/, so a
    % Variant A submission could collide with / masquerade as a baseline).
    folderParts{end+1} = sprintf('Arm%d', distressArm);
end
if expectationArm ~= 0
    folderParts{end+1} = sprintf('ExpArm%d', expectationArm);
end
if isempty(folderParts)
    saveDirectory = './Outputs/';
else
    saveDirectory = ['./Outputs_' strjoin(folderParts, '_') '/'];
end
fprintf('[Distress overlay] Writing outputs to %s\n', saveDirectory);

% Ensure output directory exists
if ~exist(saveDirectory, 'dir')
    mkdir(saveDirectory);
end

% modelRuns is computed from function arguments above as
% drawsPerTask * nRealisations. For a single-realisation legacy-mode call
% (nRealisations=1), this reduces to drawsPerTask -- matching the round-1/2/3
% behaviour exactly. For multi-realisation calibration (nRealisations=3 from
% round 4 onward), it expands so that every parameter draw is run multiple
% times with different RNG seeds.
fprintf('Runs this task: %d draws x %d realisations = %d total iterations.\n', ...
        drawsPerTask, nRealisations, modelRuns);

% Load narrowed bounds from the previous round if present; otherwise build
% the full wide-prior parameter table from scratch. The explicit log lines
% below make the mode unambiguous in the .out file -- a round that was meant
% to use narrowed bounds but prints "FRESH WIDE priors" means
% updatedMCParams.mat was missing from every searched location (silent
% fallback), which previously went unnoticed and caused a round to
% re-explore the full prior space instead of the narrowed one.
%
% Search order (first match wins):
%   1. ./Calibration Testing/updatedMCParams.mat
%      (where buildNextRound.m writes it by default, so the file lands
%       in the right place without a manual move)
%   2. ./updatedMCParams.mat
%      (legacy location at the MIDAS project root, kept for backward
%       compatibility with older workflows that staged the file there)
searchPaths = { ...
    fullfile('Calibration Testing', 'updatedMCParams.mat'), ...
    'updatedMCParams.mat' };
foundPath = '';
for kPath = 1:numel(searchPaths)
    if exist(searchPaths{kPath}, 'file') == 2
        foundPath = searchPaths{kPath};
        break;
    end
end

try
    if isempty(foundPath)
        error('runMIDASExperiment:noUpdatedMCParams', ...
              'updatedMCParams.mat not found in any of: %s', strjoin(searchPaths, ' | '));
    end
    loaded = load(foundPath);
    mcParams = loaded.mcParams;
    fprintf('Loaded NARROWED bounds from %s (%d parameters).\n', ...
            foundPath, height(mcParams));
catch

    fprintf('No updatedMCParams.mat found -- building FRESH WIDE priors.\n');

    %define the parameter space (same as runMIDASExperiment.m)
    mcParams = table([],[],[],[],'VariableNames',{'Name','Lower','Upper','RoundYN'});

    mcParams = [mcParams; {'modelParameters.spinupTime', 8, 20, 1}];
    mcParams = [mcParams; {'modelParameters.numAgents', 3000, 6000, 1}];
    mcParams = [mcParams; {'modelParameters.utility_k', 1, 5, 0}];
    mcParams = [mcParams; {'modelParameters.utility_m', 1, 2, 0}];
    mcParams = [mcParams; {'modelParameters.utility_noise', 0, 0.1, 0}];
    mcParams = [mcParams; {'modelParameters.utility_iReturn', 0, 0.2, 0}];
    mcParams = [mcParams; {'modelParameters.utility_iDiscount', 0, 0.1, 0}];
    mcParams = [mcParams; {'modelParameters.utility_iYears', 10, 20, 1}];
    mcParams = [mcParams; {'modelParameters.remitRate', 0, 20, 0}];
    mcParams = [mcParams; {'mapParameters.movingCostPerMile', 0, 5000, 0}];
    mcParams = [mcParams; {'mapParameters.minDistForCost', 0, 50, 0}];
    mcParams = [mcParams; {'mapParameters.maxDistForCost', 0, 5000, 0}];
    mcParams = [mcParams; {'networkParameters.networkDistanceSD', 5, 15, 1}];
    mcParams = [mcParams; {'networkParameters.connectionsMean', 1, 5, 1}];
    mcParams = [mcParams; {'networkParameters.connectionsSD', 1, 3, 1}];
    mcParams = [mcParams; {'networkParameters.weightLocation', 5, 15, 0}];
    mcParams = [mcParams; {'networkParameters.weightNetworkLink', 5, 15, 0}];
    mcParams = [mcParams; {'networkParameters.weightSameLayer', 3, 10, 0}];
    mcParams = [mcParams; {'networkParameters.distancePolynomial', 0.0001, 0.0003, 0}];
    mcParams = [mcParams; {'networkParameters.decayPerStep', 0.001, 0.01, 0}];
    mcParams = [mcParams; {'networkParameters.interactBump', 0.005, 0.03, 0}];
    mcParams = [mcParams; {'networkParameters.shareBump', 0.0005, 0.005, 0}];
    mcParams = [mcParams; {'agentParameters.incomeShareFractionMean', 0.01, 0.6, 0}];
    mcParams = [mcParams; {'agentParameters.incomeShareFractionSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.shareCostThresholdMean', 0.2, 0.6, 0}];
    mcParams = [mcParams; {'agentParameters.shareCostThresholdSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.interactMean', 0.2, 0.6, 0}];
    mcParams = [mcParams; {'agentParameters.interactSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.meetNewMean', 0.2, 0.6, 0}];
    mcParams = [mcParams; {'agentParameters.meetNewSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.probAddFitElementMean', 0.1, 0.7, 0}];
    mcParams = [mcParams; {'agentParameters.probAddFitElementSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.randomLearnMean', 0.1, 0.7, 0}];
    mcParams = [mcParams; {'agentParameters.randomLearnSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.randomLearnCountMean', 1, 3, 1}];
    mcParams = [mcParams; {'agentParameters.randomLearnCountSD', 0, 2, 1}];
    mcParams = [mcParams; {'agentParameters.chooseMean', 0.2, 0.9, 0}];
    mcParams = [mcParams; {'agentParameters.chooseSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.knowledgeShareFracMean', 0.01, 0.4, 0}];
    mcParams = [mcParams; {'agentParameters.knowledgeShareFracSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.bestLocationMean', 1, 3, 1}];
    mcParams = [mcParams; {'agentParameters.bestLocationSD', 0, 2, 1}];
    mcParams = [mcParams; {'agentParameters.bestPortfolioMean', 1, 3, 1}];
    mcParams = [mcParams; {'agentParameters.bestPortfolioSD', 0, 2, 1}];
    mcParams = [mcParams; {'agentParameters.randomLocationMean', 1, 3, 1}];
    mcParams = [mcParams; {'agentParameters.randomLocationSD', 0, 2, 1}];
    mcParams = [mcParams; {'agentParameters.randomPortfolioMean', 1, 3, 1}];
    mcParams = [mcParams; {'agentParameters.randomPortfolioSD', 0, 2, 1}];
    mcParams = [mcParams; {'agentParameters.numPeriodsEvaluateMean', 6, 24, 1}];
    mcParams = [mcParams; {'agentParameters.numPeriodsEvaluateSD', 0, 6, 1}];
    mcParams = [mcParams; {'agentParameters.numPeriodsMemoryMean', 6, 24, 1}];
    mcParams = [mcParams; {'agentParameters.numPeriodsMemorySD', 0, 6, 1}];
    mcParams = [mcParams; {'agentParameters.discountRateMean', 0.02, 0.1, 0}];
    mcParams = [mcParams; {'agentParameters.discountRateSD', 0, 0.02, 0}];
    mcParams = [mcParams; {'agentParameters.rValueMean', 0.75, 1.5, 0}];
    mcParams = [mcParams; {'agentParameters.rValueSD', 0.1, 0.4 , 0}];
    mcParams = [mcParams; {'agentParameters.bListMean', 0.5, 1, 0}];
    mcParams = [mcParams; {'agentParameters.bListSD', 0, 0.4, 0}];
    mcParams = [mcParams; {'agentParameters.prospectLossMean', 1, 2, 0}];
    mcParams = [mcParams; {'agentParameters.prospectLossSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.informedExpectedProbJoinLayerMean', 0.8, 1, 0}];
    mcParams = [mcParams; {'agentParameters.informedExpectedProbJoinLayerSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.uninformedMaxExpectedProbJoinLayerMean', 0, 0.4, 0}];
    mcParams = [mcParams; {'agentParameters.uninformedMaxExpectedProbJoinLayerSD', 0, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.expectationDecayMean', 0.05, 0.2, 0}];
    mcParams = [mcParams; {'agentParameters.expectationDecaySD', 0, 0.2, 0}];

    % Subsistence threshold: per-timestep cost subtracted from agent wealth
    % and used as the food-insecurity threshold (netIncome < subsistence_costs
    % flags the timestep as food-insecure). Previously hard-coded at 0.3 in
    % readParameters.m, which was an arbitrary number. Utility layers emit
    % incomes in the ~8-50 range per timestep, so a wide bracket spanning
    % roughly two orders of magnitude gives the calibration room to find a
    % value that produces realistic food-insecurity rates against the
    % Harvey et al. (2014) target of ~0.317.
    mcParams = [mcParams; {'agentParameters.subsistence_costs', 0.1, 10, 0}];

    % Urban income multiplier: scales the mean_utility of every non-ag
    % (localOnly == 0) utility layer for the whole run. The within-ag
    % relative incomes are anchored by FAO yield data and GRMA drought
    % modulation, but the urban-vs-ag absolute ratio in
    % utility_layers_v1.csv has no empirical basis. This single parameter
    % is the dominant lever for the urban-fraction calibration target.
    % Once calibrated, bake the chosen multiplier into the CSV and remove
    % the parameter for production runs.
    mcParams = [mcParams; {'modelParameters.urbanIncomeMultiplier', 0.5, 1.5, 0}];

    % Drought sensitivity (SPEI -> yield-factor mapping). Used by
    % createUtilityLayers.m in two places:
    %   (a) Observation period 1985-2022: perturbs the GRMA baseline yield
    %       factor by  delta = droughtScaleFactor * SPEI6_observed
    %       using ERA5 SPEI-6 read from observed_spei_harvest.csv.
    %   (b) Projection period 2023+: same perturbation but with SPEI
    %       sampled from the region-specific Markov chain (gated by
    %       modelParameters.droughtVariabilityOn).
    % Calibration learns the right sensitivity from observed migration
    % responses to observed historical droughts. The learned value
    % carries forward unchanged into the projection-period drought
    % perturbation, so the drought-migration coupling identified here
    % is what drives future scenarios. Bracket 0.05-0.40 covers weak
    % to strong drought sensitivity around the previous hard-coded 0.10.
    mcParams = [mcParams; {'modelParameters.droughtScaleFactor', 0.05, 0.40, 0}];

    % Distress-migration overlay (see paper Sections 4.4 / 5.1).
    % distressMigrationEnabled is a feature flag, not a calibrated parameter:
    % set it to 1 here when running the A/B overlay calibration and to 0
    % (the readParameters.m default) when running the baseline.
    % distressN is the consecutive-FI-year threshold; calibrate 1-4.
    % NB: the distress overlay parameters are appended after the catch
    % block by the safety net below, so they are added even when this
    % branch is skipped (loaded narrowed mcParams).
end

% =============================================================================
%  DISTRESS-MIGRATION OVERLAY: arm selector + parameter safety net
% =============================================================================
% The overlay is dispatched on modelParameters.distressTriggerCode:
%   1 = Variant A (consecutive FI years)
%   2 = Variant B (wealth threshold + duration)
%   3 = Variant C (cumulative wealth shortfall over rolling window)
%   4 = Variant D (stochastic depth-dependent)
%
% The arm is passed in via the 5th function argument (distressArm),
% which is forwarded from run_calibration.m -> SLURM env var
% DISTRESS_ARM. Per-variant parameters are sampled from the ranges
% given in the append loop; unused parameters (e.g. distressN for
% arms 2/3/4) just sit harmlessly in the parameter table.
DISTRESS_ARM = distressArm;

% Overlay enable flag follows the arm: 0 -> disabled (clean baseline),
% 1-4 -> enabled with that trigger variant. distressTriggerCode = 0 is
% additionally treated as 'disabled' inside checkDistressTrigger.m, so
% arm 0 is doubly safe.
distressEnabled = double(DISTRESS_ARM > 0);

distressParamSpecs = { ...
    %  name                                                Lower  Upper  RoundYN  applies-to-arms
    'modelParameters.distressMigrationEnabled',             distressEnabled, distressEnabled, 1, 'all'; ...
    'modelParameters.distressTriggerCode',                  DISTRESS_ARM, DISTRESS_ARM, 1,  'all';  ...
    'modelParameters.distressN',                            1,     4,     1,      'A';     ...
    'modelParameters.distressWealthThreshold',              0,     5,     0,      'B,C,D'; ...
    'modelParameters.distressN_quarters',                   2,     12,    1,      'B';     ...
    'modelParameters.distressShortfallWindowYears',         2,     5,     1,      'C';     ...
    'modelParameters.distressCriticalShortfall',            0.5,   10,    0,      'C';     ...
    'modelParameters.distressStochasticAlpha',              1,     10,    0,      'D';     ...
    'modelParameters.distressIncomeDropFrac',               0.3,   0.9,   0,      'E';     ...
    'modelParameters.distressIncomeWindowYears',            2,     5,     1,      'E';     ...
    'modelParameters.distressCooldownQuarters',             4,     4,     1,      'E';     ...
};

for k = 1:size(distressParamSpecs, 1)
    pname = distressParamSpecs{k,1};
    if ~ismember(pname, mcParams.Name)
        mcParams = [mcParams; {pname, distressParamSpecs{k,2}, ...
                                       distressParamSpecs{k,3}, ...
                                       distressParamSpecs{k,4}}];
        fprintf('[Distress overlay] Appended %s [%g, %g].\n', ...
                pname, distressParamSpecs{k,2}, distressParamSpecs{k,3});
    end
end
fprintf('[Distress overlay] Running ARM %d.\n', DISTRESS_ARM);

% =============================================================================
%  LOCAL DEMAND COUPLING (kappa)
% =============================================================================
% Scales non-ag layer base utility per location-year by
% 1 - kappa*(1 - mean local ag yield factor), so local non-farm income
% co-moves with the agricultural economy instead of acting as a
% drought-immune shock absorber (see createUtilityLayers.m).
% Set via SLURM env var, e.g.:
%   sbatch --export=ALL,LOCAL_DEMAND_COUPLING=0.7 HPC/submit_calibration_batch.sh
% Unset / invalid -> 0 (coupling off, legacy behaviour). To CALIBRATE kappa
% instead of fixing it, replace the [v, v] bounds below with a range.
couplingV = str2double(getenv('LOCAL_DEMAND_COUPLING'));
if isnan(couplingV) || couplingV < 0 || couplingV > 1
    couplingV = 0;
end
if ~ismember('modelParameters.localDemandCoupling', mcParams.Name)
    mcParams = [mcParams; {'modelParameters.localDemandCoupling', couplingV, couplingV, 0}];
end
if couplingV > 0
    folderParts{end+1} = sprintf('Coupling%02d', round(100 * couplingV));
end

% =============================================================================
%  POSITIVE-SPEI SCALE (post-drought rebound suppression)
% =============================================================================
% Scales only the POSITIVE observed-SPEI yield perturbations (see
% createUtilityLayers.m). 1 = symmetric/legacy; 0 = wet years never lift
% yields above the GRMA baseline. Proxy for asymmetric post-kere recovery.
% Set via SLURM env var, e.g.:
%   sbatch --export=ALL,POSITIVE_SPEI_SCALE=0 HPC/submit_calibration_batch.sh
posSpeiV = str2double(getenv('POSITIVE_SPEI_SCALE'));
if isnan(posSpeiV) || posSpeiV < 0 || posSpeiV > 1
    posSpeiV = 1;
end
if ~ismember('modelParameters.droughtPositiveSPEIScale', mcParams.Name)
    mcParams = [mcParams; {'modelParameters.droughtPositiveSPEIScale', posSpeiV, posSpeiV, 0}];
end
if posSpeiV < 1
    folderParts{end+1} = sprintf('PosSpei%02d', round(100 * posSpeiV));
end

% =============================================================================
%  LIVESTOCK/GRAIN BUFFER
% =============================================================================
% Enabled either explicitly (BUFFER env var = 1, e.g. for Stage-1 tests with
% the buffer under Variant E or no distress overlay) OR automatically when
% Variant F (distressArm == 6) is selected, since Variant F reads the buffer.
% The four CALIBRATED buffer parameters get sampling ranges here; the fixed/
% definitional ones (growth, cap, ref, phiFood, phiLv) come from the
% readParameters.m defaults and are intentionally NOT sampled.
bufferEnvV = str2double(getenv('BUFFER'));
bufferOn   = (~isnan(bufferEnvV) && bufferEnvV == 1) || (distressArm == 6);
if bufferOn
    if ~ismember('modelParameters.bufferEnabled', mcParams.Name)
        mcParams = [mcParams; {'modelParameters.bufferEnabled', 1, 1, 1}];
    end
    bufferParamSpecs = { ...
        %  name                                        Lower  Upper  RoundYN
        'modelParameters.bufferAccrualFrac',            0.1,   0.7,   0;   ...
        'modelParameters.bufferMortalityMax',          0.1,   0.5,   0;   ...
        'modelParameters.bufferFloor',                  0.0,   3.0,   0;   ...
        'modelParameters.lambdaProd',                   0.0,   0.5,   0;   ...
    };
    for k = 1:size(bufferParamSpecs, 1)
        pname = bufferParamSpecs{k,1};
        if ~ismember(pname, mcParams.Name)
            mcParams = [mcParams; {pname, bufferParamSpecs{k,2}, ...
                                          bufferParamSpecs{k,3}, ...
                                          bufferParamSpecs{k,4}}];
        end
    end
    folderParts{end+1} = 'Buffer';
    fprintf('[Livestock buffer] ENABLED (env BUFFER=%g, distressArm=%d).\n', ...
            bufferEnvV, distressArm);
end

% Recompute the output folder if any lever added a suffix.
if couplingV > 0 || posSpeiV < 1 || bufferOn
    saveDirectory = ['./Outputs_' strjoin(folderParts, '_') '/'];
    if ~exist(saveDirectory, 'dir'); mkdir(saveDirectory); end
    fprintf('[Levers] coupling kappa = %.2f, positive-SPEI scale = %.2f, buffer = %d; outputs -> %s\n', ...
            couplingV, posSpeiV, bufferOn, saveDirectory);
end

% =============================================================================
%  EXPECTATION-FORMATION OVERLAY: arm selector + parameter safety net
% =============================================================================
% Selects how an agent forms expected per-period income for candidate
% portfolios (see formExpectation.m and the dispatcher dispatched on
% modelParameters.expectationArm). Arms:
%   0 = BASELINE (current MIDAS: random stitching of complete past cycles)
%   1 = ADAPTIVE EXPECTATIONS (exp-decay weighted mean, deterministic future)
%   2 = WINDOWED RANDOM SAMPLING (baseline restricted to numPeriodsMemory)
%   3 = NAIVE FORECAST (last cycle repeated forward)
%   4 = ADAPTIVE + STOCHASTIC SHOCKS (weighted mean plus sampled residuals)
expectationParamSpecs = { ...
    %  name                                                Lower            Upper            RoundYN  applies-to-arms
    'modelParameters.expectationArm',                       expectationArm,  expectationArm,  1,      'all';   ...
    'modelParameters.expectationDecayRate',                 0.03,            0.20,            0,      '1,4';   ...
    'modelParameters.expectationShockWindow',               4,               20,              1,      '4';     ...
};

for k = 1:size(expectationParamSpecs, 1)
    pname = expectationParamSpecs{k,1};
    if ~ismember(pname, mcParams.Name)
        mcParams = [mcParams; {pname, expectationParamSpecs{k,2}, ...
                                       expectationParamSpecs{k,3}, ...
                                       expectationParamSpecs{k,4}}];
        fprintf('[Expectation arm] Appended %s [%g, %g].\n', ...
                pname, expectationParamSpecs{k,2}, expectationParamSpecs{k,3});
    end
end
fprintf('[Expectation arm] Running ARM %d.\n', expectationArm);

% Build the experimental design.
% First draw drawsPerTask UNIQUE parameter sets, then replicate each into
% nRealisations slots so the parfor loop runs modelRuns total iterations.
% Same parameter set, different RNG seeds per realisation -- buildNextRound.m
% groups by parameter vector and averages metrics before scoring.
fprintf('Building experiment list (%d unique draws x %d realisations = %d total iterations)...\n', ...
        drawsPerTask, nRealisations, modelRuns);

experimentList  = cell(modelRuns, 1);
drawIdxList     = zeros(modelRuns, 1);   % which unique draw this iteration belongs to (1..drawsPerTask)
realisationList = zeros(modelRuns, 1);   % which realisation within the draw (1..nRealisations)

for d = 1:drawsPerTask
    % Sample one parameter vector for this draw
    experiment = table([], [], 'VariableNames', {'parameterNames','parameterValues'});
    for indexJ = 1:height(mcParams)
        tempName  = mcParams.Name{indexJ};
        tempMin   = mcParams.Lower(indexJ);
        tempMax   = mcParams.Upper(indexJ);
        tempValue = tempMin + (tempMax - tempMin) * rand();
        if mcParams.RoundYN(indexJ)
            tempValue = round(tempValue);
        end
        experiment = [experiment; {tempName, tempValue}];
    end

    % Replicate the same parameter vector into nRealisations slots
    for r = 1:nRealisations
        slot = (d - 1) * nRealisations + r;
        experimentList{slot}  = experiment;
        drawIdxList(slot)     = d;
        realisationList(slot) = r;
    end
end

% Tag the experiment summary and per-run output filenames with the array
% task ID when applicable, so concurrent array tasks do not overwrite
% each other in ./Outputs/. buildNextRound.m globs MC*.mat and reads
% experiment_*.mat (taking the last match for mcParams), so unique
% per-task names are safe for the downstream evaluator.
if taskId > 0
    taskTag = sprintf('T%03d_', taskId);
else
    taskTag = '';
end

fprintf('Saving experiment list (taskTag=''%s'').\n', taskTag);
save([saveDirectory 'experiment_' date '_' taskTag 'input_summary'], ...
     'experimentList', 'mcParams', 'taskId', ...
     'drawsPerTask', 'nRealisations', ...
     'drawIdxList', 'realisationList');

% Pre-generate output filenames (required for parfor slicing). For
% multi-realisation runs use the _D<draw>_R<realisation> tag so
% buildNextRound.m can detect grouping (it also detects by hashing
% parameter values, so this is belt-and-braces). For single-realisation
% legacy runs keep the original ..._<run>_<date>.mat naming.
outputFiles = cell(modelRuns, 1);
for indexI = 1:modelRuns
    if nRealisations > 1
        fname = sprintf('%s%s%sD%03d_R%d_%s.mat', ...
                        saveDirectory, series, taskTag, ...
                        drawIdxList(indexI), realisationList(indexI), ...
                        datestr(now,'yyyy-mm-dd'));
    else
        fname = sprintf('%s%s%s%d_%s.mat', ...
                        saveDirectory, series, taskTag, indexI, ...
                        datestr(now,'yyyy-mm-dd'));
    end
    fname = strrep(fname, ':', '-');
    fname = strrep(fname, ' ', '_');
    outputFiles{indexI} = fname;
end

fprintf('Launching parfor loop with %d runs...\n', modelRuns);

% parfor requires all variables accessed inside to be sliced or broadcast
parfor indexI = 1:modelRuns
    try
        % Deterministic per-(task, draw, realisation) RNG seed. parfor
        % workers run in independent processes with their own RNG state,
        % so we re-seed at the START of each iteration to guarantee that
        % (a) realisations of the SAME parameter set get DIFFERENT seeds
        % and (b) re-running a specific (task, draw, realisation) triple
        % reproduces its output exactly.
        if taskId > 0
            rng(taskId * 10000 + drawIdxList(indexI) * 10 + realisationList(indexI));
        end

        input  = experimentList{indexI};
        runLabel = sprintf('Task %d Draw %d Realisation %d', ...
                           taskId, drawIdxList(indexI), realisationList(indexI));
        output = midasMainLoop(input, runLabel);

        functionVersions = inmem('-completenames');
        functionVersions = functionVersions(strmatch(pwd, functionVersions));
        output.codeUsed  = functionVersions;

        % Tag the saved output with draw/realisation indices so downstream
        % code can group runs even when filenames are not parsed.
        output.taskId         = taskId;
        output.drawIdx        = drawIdxList(indexI);
        output.realisationIdx = realisationList(indexI);

        currentFile = outputFiles{indexI};
        saveToFile(input, output, currentFile);
        fprintf('  Iter %d/%d (D%d R%d) complete -> %s\n', ...
                indexI, modelRuns, drawIdxList(indexI), realisationList(indexI), currentFile);
    catch ME
        fprintf('  Iter %d/%d (D%d R%d) FAILED: %s\n', ...
                indexI, modelRuns, drawIdxList(indexI), realisationList(indexI), ME.message);
        for kStack = 1:length(ME.stack)
            fprintf('    at %s (line %d)\n', ME.stack(kStack).name, ME.stack(kStack).line);
        end
    end
end

fprintf('All runs complete.\n');

end % function


function saveToFile(input, output, filename)
    save(filename, 'input', 'output');
end
