function repair_geometry_cache(varargin)
% repair_geometry_cache  --  add correct region names to the cached geometry
%
%   repair_geometry_cache
%   repair_geometry_cache('DryRun', true)
%
% WHY THIS EXISTS
% Data/Mada Admin 2/Admin_2_lat_lon.mat caches the rasterised map so that
% createMapFromSHP does not have to rebuild it every run. The cached
% `locations` table lacks a source_NAME_2 column, so createUtilityLayers falls
% back to source_ADM2_FR -- a 15-CHARACTER DBF field that TRUNCATES:
%
%     'Atsimo-Andrefana'     -> 'Atsimo-Andrefan'
%     'Vatovavy Fitovinany'  -> 'Vatovavy Fitovi'
%
% Exactly two of the 22 Madagascar region names exceed 15 characters, and
% those two therefore failed every drought lookup: the GRMA yield surfaces,
% the observed SPEI record, the Markov parameters and the correlation matrix.
% yieldFactor is initialised to ones() and only matched locations are written,
% so both ran with NO drought forcing at all -- silently. One of them,
% Atsimo-Andrefana, is a Grand Sud study region.
%
% WHY NOT JUST REBUILD
% Because the rebuild path no longer works on current MATLAB:
%
%     Error using vec2mtx
%     Referencing vectors and referencing matrices are no longer accepted as
%     input. Use a geographic raster reference object as input instead.
%
% createMapFromSHP passes r1 = [density maxY minX], a referencing vector that
% the Mapping Toolbox removed support for. The cache was built years ago on an
% older release and has been carrying the project ever since. Fixing vec2mtx
% properly means constructing a georasterref object and re-verifying the
% rasterisation, which is a job for after the campaign, not before it.
%
% This script therefore repairs the cache WITHOUT rasterising. shaperead still
% works -- only vec2mtx fails -- so the true names can be read straight from
% the shapefile and written into the cached table. The map and borders rasters
% are untouched.

p = inputParser;
addParameter(p, 'ShapeFile', './Data/Mada Admin 2/Admin_2_lat_lon.shp');
addParameter(p, 'DryRun', false);
parse(p, varargin{:});
opt = p.Results;

cacheFile = [opt.ShapeFile '.mat'];
cacheFile = strrep(cacheFile, '.shp.mat', '.mat');
if ~exist(cacheFile, 'file')
    error('repair_geometry_cache:noCache', ...
          ['%s not found. If you deleted it, restore with:\n' ...
           '    git checkout -- "Data/Mada Admin 2/Admin_2_lat_lon.mat"'], cacheFile);
end

fprintf('Cache : %s\n', cacheFile);
C = load(cacheFile);
if ~isfield(C, 'locations')
    error('repair_geometry_cache:badCache', 'cache has no locations table');
end
locations = C.locations;
nLoc = height(locations);
fprintf('        %d locations, fields: %s\n', nLoc, ...
        strjoin(locations.Properties.VariableNames( ...
            startsWith(locations.Properties.VariableNames, 'source_')), ', '));

% ---- read the authoritative names from the shapefile --------------------
fprintf('Shape : %s\n', opt.ShapeFile);
S = shaperead(opt.ShapeFile);
if numel(S) ~= nLoc
    error('repair_geometry_cache:rowMismatch', ...
          ['shapefile has %d records but the cached table has %d rows. ' ...
           'These must correspond one-to-one; aborting rather than guessing.'], ...
          numel(S), nLoc);
end
trueNames = string({S.NAME_2}');

% ---- verify the ordering before writing anything ------------------------
% The cached rows and the shapefile records must be in the same order. If the
% cache holds a truncated name field, every truncated value should be a PREFIX
% of the corresponding shapefile name. That is a strong check: a mismatched
% ordering would fail it immediately, and writing names into the wrong rows
% would be far worse than the bug being fixed.
checkFld = '';
for f = {'source_ADM2_FR', 'source_NAME_2'}
    if ismember(f{1}, locations.Properties.VariableNames); checkFld = f{1}; break; end
end
if isempty(checkFld)
    error('repair_geometry_cache:noCheckField', ...
          'no source_ADM2_FR or source_NAME_2 in the cache to verify ordering against');
end
existing = strtrim(string(locations.(checkFld)));
ok = arrayfun(@(a, b) startsWith(b, a), existing, trueNames);
fprintf('\nOrdering check against %s: %d of %d rows consistent\n', ...
        checkFld, sum(ok), nLoc);
if ~all(ok)
    bad = find(~ok);
    for iB = bad(:)'
        fprintf('  row %2d: cache has "%s", shapefile has "%s"\n', ...
                iB, existing(iB), trueNames(iB));
    end
    error('repair_geometry_cache:orderMismatch', ...
          ['cached rows do not line up with shapefile records. Repairing would ' ...
           'assign names to the wrong regions; aborting.']);
end

% ---- report what will change -------------------------------------------
% DIFF AGAINST THE FIELD BEING WRITTEN, NOT THE ORDERING-CHECK FIELD.
% The check above deliberately prefers source_ADM2_FR because a truncated
% value is a valid PREFIX of the full name, which makes startsWith a strong
% test of row alignment. Reporting the diff against that same field is
% useless: ADM2_FR is a 15-character DBF field, so it will always differ on
% the two long names, and an already-repaired cache reports "2 names will
% change" forever. That is exactly what it did on 2026-09-04, and it reads
% like a broken cache when nothing is wrong.
%
% What matters is source_NAME_2 -- the field this script writes and the field
% every downstream drought lookup keys on.
if ismember('source_NAME_2', locations.Properties.VariableNames)
    target = strtrim(string(locations.source_NAME_2));
    targetFld = 'source_NAME_2';
else
    target = strings(nLoc, 1);   % absent: every row is a change
    targetFld = 'source_NAME_2 (absent -- will be added)';
end
changed = find(target ~= trueNames);
fprintf('\nComparing %s against the shapefile:\n', targetFld);
fprintf('%d name(s) will change:\n', numel(changed));
for iC = changed(:)'
    fprintf('  row %2d: "%s"  ->  "%s"\n', iC, target(iC), trueNames(iC));
end
if isempty(changed)
    fprintf(['  (none -- cache already carries full names, nothing to do)\n' ...
             '  NOTE: source_ADM2_FR still holds truncated values. That is\n' ...
             '  correct and expected -- it is a 15-character DBF field, and\n' ...
             '  nothing reads it once source_NAME_2 is present.\n']);
end

if opt.DryRun
    fprintf('\nDRY RUN -- nothing written. Re-run without ''DryRun'' to apply.\n');
    return;
end

% ---- write ---------------------------------------------------------------
backup = [cacheFile '.bak_' datestr(now, 'yyyymmdd_HHMMSS')];
copyfile(cacheFile, backup);
fprintf('\nBackup: %s\n', backup);

locations.source_NAME_2 = cellstr(trueNames);
C.locations = locations;

% Save under the same variable names createMapFromSHP's load branch expects.
map = C.map; borders = C.borders; mapParameters = C.mapParameters; %#ok<NASGU>
save(cacheFile, 'locations', 'map', 'borders', 'mapParameters');
fprintf('Wrote : %s\n', cacheFile);

fprintf(['\nDone. createMapFromSHP will now accept this cache, so no rebuild is\n' ...
         'attempted and vec2mtx is never called. Verify with:\n' ...
         '    make_drought_state_panel\n' ...
         'expecting "drought forcing matched for %d of %d regions" and no\n' ...
         'truncation warnings.\n'], nLoc, nLoc);
end
