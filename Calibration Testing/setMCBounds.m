function setMCBounds(overrides, matPath)
% setMCBounds  --  safely edit the narrowed bounds in updatedMCParams.mat
%
%   setMCBounds                                  % just print current bounds
%   setMCBounds({'agentParameters.subsistence_costs', 2.5, 3.5; ...
%                'modelParameters.droughtScaleFactor', 0.05, 0.40})
%
% WHY THIS EXISTS
% updatedMCParams.mat holds a TABLE (mcParams) with columns Name, Lower,
% Upper, RoundYN. Editing it by hand in the workspace is easy to get wrong in
% ways that fail silently: assigning to the wrong row, saving the variable
% under a different name so runMIDASExperiment_parallel cannot find it,
% dropping the RoundYN flag so an integer parameter starts drawing fractions,
% or writing Lower > Upper. None of those produce an error at save time --
% they produce a bad campaign.
%
% This does the edit by NAME, validates, backs up, and prints a before/after
% table so the change is visible before it is used.
%
%   overrides : N x 3 cell array {parameterName, newLower, newUpper}
%               Names must match mcParams.Name exactly (with the dots).
%
%               N x 4 form {parameterName, newLower, newUpper, roundYN} is
%               permitted ONLY to introduce a parameter the table does not yet
%               carry. The 3-column form still errors on an unknown name, which
%               is what catches typos; requiring the extra column to create a
%               row means a parameter can never be added by accident.
%
%   matPath   : optional path to updatedMCParams.mat. Defaults to the copy in
%               this folder, then the project root.
%
% SIDECAR
% Every call also writes updatedMCParams_bounds.csv beside the .mat. The .mat
% remains the single source of truth -- it is what the runner loads and the
% only thing the model reads -- but it is binary, so it cannot be diffed, read
% in an editor, or checked by a shell script. The sidecar is a derived copy for
% those three jobs and is never read back by anything.

if nargin < 1; overrides = {}; end

% ---- locate the file ---------------------------------------------------
if nargin < 2 || isempty(matPath)
    candidates = {fullfile(fileparts(mfilename('fullpath')), 'updatedMCParams.mat'), ...
                  'updatedMCParams.mat', ...
                  fullfile('Calibration Testing', 'updatedMCParams.mat')};
    matPath = '';
    for k = 1:numel(candidates)
        if exist(candidates{k}, 'file') == 2; matPath = candidates{k}; break; end
    end
    if isempty(matPath)
        error('setMCBounds:notFound', ...
            ['No updatedMCParams.mat found. Run buildNextRound first -- and check ' ...
             'it printed "Saved updatedMCParams.mat", because it returns early ' ...
             'without writing if no experiment_*.mat is present.']);
    end
end
fprintf('Using %s\n', matPath);

L = load(matPath);
if ~isfield(L, 'mcParams')
    error('setMCBounds:noVar', ...
        ['%s does not contain a variable called mcParams. ' ...
         'runMIDASExperiment_parallel loads it by that name, so it must be ' ...
         'saved as mcParams or it will silently fall back to wide priors.'], matPath);
end
mcParams = L.mcParams;

% ---- apply overrides ---------------------------------------------------
% Must be 0x5, not {}. An empty 0x0 cell has no second dimension, so the
% changed(:,1) lookup in the report loop below errors when called with no
% overrides -- which is the commonest use, listing the bounds.
changed = cell(0, 5);
for k = 1:size(overrides, 1)
    nm = overrides{k, 1};
    lo = overrides{k, 2};
    hi = overrides{k, 3};

    mayCreate = size(overrides, 2) >= 4 && ~isempty(overrides{k, 4});

    idx = find(strcmp(mcParams.Name, nm));
    if isempty(idx) && mayCreate
        % Deliberate introduction of a parameter the calibration never carried
        % -- typically one fixed by declaration rather than fitted. Validate
        % before appending: a row added with the wrong RoundYN would start an
        % integer parameter drawing fractions, silently.
        rnd = overrides{k, 4};
        if ~(isscalar(rnd) && (islogical(rnd) || (isnumeric(rnd) && ismember(rnd, [0 1]))))
            error('setMCBounds:badRoundYN', ...
                'RoundYN for new parameter "%s" must be 0 or 1.', nm);
        end
        if hi < lo
            error('setMCBounds:inverted', ...
                'Upper (%g) is below Lower (%g) for new parameter "%s".', hi, lo, nm);
        end
        mcParams = [mcParams; {nm, lo, hi, double(rnd)}]; %#ok<AGROW>
        changed(end+1, :) = {nm, NaN, NaN, lo, hi}; %#ok<AGROW>
        fprintf('ADDED %s as a new row [%g, %g], RoundYN %d.\n', nm, lo, hi, rnd);
        continue;
    end
    if isempty(idx)
        % Fail loudly. A typo here would otherwise leave the parameter at its
        % calibrated bound while you believed you had overridden it.
        error('setMCBounds:badName', ...
            ['Parameter "%s" is not in mcParams. Check the exact spelling ' ...
             '(including the struct prefix). Run setMCBounds with no ' ...
             'arguments to list every name.\nIf you mean to CREATE it, pass a ' ...
             'fourth column giving RoundYN: {''%s'', %g, %g, 0}.'], nm, nm, lo, hi);
    end
    if numel(idx) > 1
        error('setMCBounds:duplicate', 'Parameter "%s" appears %d times.', nm, numel(idx));
    end
    if ~(isnumeric(lo) && isnumeric(hi) && isscalar(lo) && isscalar(hi))
        error('setMCBounds:badBounds', 'Bounds for "%s" must be numeric scalars.', nm);
    end
    if hi < lo
        error('setMCBounds:inverted', ...
            'Upper (%g) is below Lower (%g) for "%s".', hi, lo, nm);
    end
    if mcParams.RoundYN(idx) && (lo ~= floor(lo) || hi ~= ceil(hi))
        warning('setMCBounds:nonInteger', ...
            ['"%s" is flagged RoundYN (integer-valued) but the bounds given ' ...
             'are not integers. They will be rounded by the sampler.'], nm);
    end

    changed(end+1, :) = {nm, mcParams.Lower(idx), mcParams.Upper(idx), lo, hi}; %#ok<AGROW>
    mcParams.Lower(idx) = lo;
    mcParams.Upper(idx) = hi;
end

% ---- report ------------------------------------------------------------
fprintf('\n=== ALL BOUNDS (%d parameters) ===\n', height(mcParams));
fprintf('%-48s %12s %12s %6s\n', 'parameter', 'lower', 'upper', 'int');
changedNames = changed(:, 1);   % 0x1 when nothing was overridden
for k = 1:height(mcParams)
    nmK = mcParams.Name{k};
    flag = '';
    if ~isempty(changedNames) && any(strcmp(changedNames, nmK))
        flag = '  <== CHANGED';
    end
    % Flag any parameter whose range has collapsed to a point -- effectively
    % fixed, which the narrowing can do accidentally when the top-scoring runs
    % all share a value.
    if mcParams.Upper(k) - mcParams.Lower(k) <= 1e-9
        flag = [flag '  [FIXED]']; %#ok<AGROW>
    end
    fprintf('%-48s %12.5g %12.5g %6d%s\n', nmK, ...
            mcParams.Lower(k), mcParams.Upper(k), mcParams.RoundYN(k), flag);
end

% Degenerate ranges are worth seeing: a parameter whose bounds collapsed to a
% point is effectively fixed, which may or may not be intended.
degenerate = find(mcParams.Upper - mcParams.Lower <= 1e-9);
if ~isempty(degenerate)
    fprintf('\nFIXED (upper == lower), %d parameters:\n', numel(degenerate));
    for k = degenerate(:)'
        fprintf('   %-48s %g\n', mcParams.Name{k}, mcParams.Lower(k));
    end
end

if isempty(overrides)
    fprintf('\nNo overrides given -- the .mat is unchanged.\n');
    writeSidecar(mcParams, matPath);
    return;
end

fprintf('\n=== CHANGES ===\n');
for k = 1:size(changed, 1)
    if isnan(changed{k,2})
        fprintf('  %-46s (new row) -> [%g, %g]\n', changed{k,1}, ...
                changed{k,4}, changed{k,5});
    else
        fprintf('  %-46s [%g, %g] -> [%g, %g]\n', changed{k,1}, ...
                changed{k,2}, changed{k,3}, changed{k,4}, changed{k,5});
    end
end

% ---- back up and save --------------------------------------------------
bak = [matPath '.bak_' datestr(now, 'yyyymmdd_HHMMSS')];
copyfile(matPath, bak);
save(matPath, 'mcParams');
fprintf('\nBacked up to %s\n', bak);
fprintf('Wrote %s\n', matPath);
writeSidecar(mcParams, matPath);
fprintf(['\nVerify before submitting: the experiment log must say\n' ...
         '  "Loaded NARROWED bounds from ... (%d parameters)"\n' ...
         'If it says "building FRESH WIDE priors", the file is not where the\n' ...
         'runner looks and none of this took effect.\n'], height(mcParams));
end

% =========================================================================
function writeSidecar(mcParams, matPath)
% Plain-text mirror of the bounds, written beside the .mat.
%
% The .mat stays the single source of truth: it is what the runner loads and
% the only thing the model reads. This file exists because the .mat is binary
% and therefore cannot be diffed in git, opened in an editor, or checked by
% preflight.sh. Nothing ever reads it back, so it cannot drift into being a
% second definition -- if it disagrees with the .mat, the .mat is right and
% this file is merely stale.
csvPath = strrep(matPath, '.mat', '_bounds.csv');
T = table(mcParams.Name, mcParams.Lower, mcParams.Upper, mcParams.RoundYN, ...
          'VariableNames', {'name','lower','upper','roundYN'});
T = sortrows(T, 'name');
try
    writetable(T, csvPath);
    fprintf('Wrote sidecar %s (%d parameters).\n', csvPath, height(T));
catch err
    warning('setMCBounds:sidecarFailed', ...
            ['Could not write %s (%s). The .mat is still correct -- only the ' ...
             'human-readable mirror is missing.'], csvPath, err.message);
end
end
