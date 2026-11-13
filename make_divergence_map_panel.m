function out = make_divergence_map_panel(varargin)
% make_divergence_map_panel  --  panel (b) of the drought workflow figure
%
%   make_divergence_map_panel
%   make_divergence_map_panel('Year', 2050, 'Labels', 'all')
%
% WHAT IT SHOWS
% A choropleth of Madagascar's 22 admin-2 regions, shaded by
%
%     SSP2-4.5 yield factor  minus  SSP5-8.5 yield factor,   at 2085
%
% in the mean GRMA yield factor across the agricultural layers each region
% actually has. Positive (red) means the high-emissions scenario is WORSE
% there; negative (blue) means it is better. Colours match panel (a), where
% SSP2 is blue and SSP5 red, so red on this map reads as "more SSP5".
%
% WHY LAYER-AWARE AND NOT A FLAT CROP AVERAGE
% utility_layers_v1.csv gives rice to two disjoint region sets and to nobody
% else. Eight regions -- including all three Grand Sud regions -- have maize
% and cassava only. Averaging three crops everywhere would plot rice yields
% in regions where the model has no rice, and would do it most wrongly in the
% regions the paper is about. grmaLayerMeanYield reproduces the agYF
% construction from createUtilityLayers exactly; panel (a) calls the same
% function, so the two panels cannot disagree.
%
% WHY THE SECULAR COMPONENT ONLY
% No Markov realisation enters this map. The scenario signal is the GRMA
% trajectory; interannual variability is stationary and identical in
% distribution across scenarios, so including one realisation would add noise
% that is not a scenario difference and would make the map unreproducible.
% Panels (c) and (d) are where variability is displayed.
%
% WHAT THE NUMBERS ACTUALLY SAY  (2085, layer-aware)
%   Androy            +0.103      Betsiboka        +0.047
%   Atsimo-Andrefana  +0.049      Sofia            +0.043
%   Anosy             +0.045      Boeny            +0.036
%   national mean     +0.021      Grand Sud mean   +0.066   (3.19x)
%
% Read honestly, the pattern is NOT "divergence is concentrated in the Grand
% Sud". Betsiboka, Sofia and Boeny -- north-west, not southern -- sit between
% Atsimo-Andrefana and Anosy in the ranking. The defensible statement is that
% divergence concentrates in the dry west and south, and that Androy is
% exceptional at roughly double the next region. The map is worth showing
% precisely because it makes that qualification unavoidable.
%
% GEOMETRY
% Read straight from the shapefile with shaperead. The rasterised cache is
% not used and vec2mtx is never called, so this panel is unaffected by the
% broken rebuild path (see repair_geometry_cache.m).

p = inputParser;
addParameter(p, 'Year',      2085);
addParameter(p, 'DataDir',   './Data');
addParameter(p, 'LayerFile', './Data/utility_layers_v1.csv');
addParameter(p, 'ShapeFile', './Data/Mada Admin 2/Admin_2_lat_lon.shp');
addParameter(p, 'South',     {'Androy', 'Anosy', 'Atsimo-Andrefana'});
% LABELS. 'south' names the three Grand Sud regions, which the outline on the
% map needs explaining anyway. 'all' writes the divergence value into every
% region -- legible at standalone size, illegible inside a four-panel
% composite, which is why it is not the default. 'none' for the composite.
addParameter(p, 'Labels',    'south');
addParameter(p, 'OutFile',   './Outputs/fig_panel_b_divergence_map.png');
addParameter(p, 'Axes',      []);
addParameter(p, 'Standalone', true);
parse(p, varargin{:});
opt = p.Results;

SOUTH = string(opt.South);

% ---- divergence ---------------------------------------------------------
[Y2, regNames, years, info] = grmaLayerMeanYield('SSP2', ...
    'DataDir', opt.DataDir, 'LayerFile', opt.LayerFile, 'EndYear', opt.Year);
Y5 = grmaLayerMeanYield('SSP5', ...
    'DataDir', opt.DataDir, 'LayerFile', opt.LayerFile, 'EndYear', opt.Year);

k = find(years == opt.Year, 1);
if isempty(k)
    error('make_divergence_map_panel:noYear', ...
          'year %d is not in the GRMA surfaces (they run %d-%d)', ...
          opt.Year, years(1), years(end));
end
div = Y2(:, k) - Y5(:, k);

% ---- geometry -----------------------------------------------------------
if ~exist(opt.ShapeFile, 'file')
    error('make_divergence_map_panel:noShapefile', '%s not found', opt.ShapeFile);
end
S = shaperead(opt.ShapeFile);
shpNames = strtrim(string({S.NAME_2}'));

% MATCH BY NAME, NOT BY ROW ORDER. The shapefile and the GRMA surfaces are
% independent files and nothing guarantees they agree on ordering. Matching
% positionally would silently paint each region with its neighbour's value --
% a failure that looks like a plausible map, which is the worst kind.
idx = nan(numel(S), 1);
for iS = 1:numel(S)
    r = find(regNames == shpNames(iS), 1);
    if ~isempty(r); idx(iS) = r; end
end
missing = find(isnan(idx));
if ~isempty(missing)
    error('make_divergence_map_panel:unmatched', ...
          ['%d shapefile region(s) have no GRMA row: %s.\nGRMA region names: %s'], ...
          numel(missing), strjoin(cellstr(shpNames(missing)), ', '), ...
          strjoin(cellstr(regNames), ', '));
end
if numel(unique(idx)) ~= numel(regNames)
    warning(['%d GRMA region(s) were not drawn -- present in the surfaces but ' ...
             'absent from the shapefile.'], numel(regNames) - numel(unique(idx)));
end

% Report multipart geometries. Each part is patched separately with the same
% colour, which is correct for offshore islands. It would overpaint an
% enclave, so make it visible rather than assume.
nParts = arrayfun(@(s) sum(isnan(s.X)) , S);
if any(nParts > 1)
    fprintf('note: %d region(s) have multipart geometry (islands): %s\n', ...
            sum(nParts > 1), strjoin(cellstr(shpNames(nParts > 1)), ', '));
end

% ---- colour scale -------------------------------------------------------
% ASYMMETRIC, WHITE PINNED AT ZERO. Symmetric limits would spend half the
% colour range on a negative tail that reaches only -0.010, flattening the
% positive spread that is the actual result. Zero must still be white, since
% "no scenario difference" is the meaningful reference, so the colormap is
% built with its white point at the right fraction rather than the middle.
pad = 0.005;
c1 = ceil((max(div) + pad) * 100) / 100;
c0 = floor((min(min(div) - pad, -pad)) * 100) / 100;
cm = asymmetricDiverging(c0, c1, 256);

% ---- axes ---------------------------------------------------------------
if isempty(opt.Axes)
    fig = figure('Position', [100 100 620 760], 'Color', 'w');
    ax  = axes(fig);
else
    ax  = opt.Axes;
    fig = ancestor(ax, 'figure');
end
hold(ax, 'on'); box(ax, 'on');
colormap(ax, cm);
setCLim(ax, [c0 c1]);

BORDER = [0.45 0.45 0.45];
cmVals = linspace(c0, c1, size(cm, 1));
fillCol = zeros(numel(S), 3);

for iS = 1:numel(S)
    v   = min(max(div(idx(iS)), c0), c1);
    col = interp1(cmVals, cm, v, 'linear');
    fillCol(iS, :) = col;
    parts = splitOnNaN(S(iS).X, S(iS).Y);
    for iP = 1:numel(parts)
        % Name-value form rather than patch(ax, X, Y, C): a bare 1x3 C is
        % ambiguous between an RGB triplet and per-vertex colour data, and
        % which one patch picks depends on the vertex count.
        patch(ax, 'XData', parts{iP}(:, 1), 'YData', parts{iP}(:, 2), ...
              'FaceColor', col, 'EdgeColor', BORDER, 'LineWidth', 0.4, ...
              'HandleVisibility', 'off');
    end
end

% GRAND SUD OUTLINE, drawn after every fill so it is never overpainted by a
% neighbour's edge.
for iS = 1:numel(S)
    if ~ismember(shpNames(iS), SOUTH); continue; end
    parts = splitOnNaN(S(iS).X, S(iS).Y);
    for iP = 1:numel(parts)
        plot(ax, parts{iP}(:, 1), parts{iP}(:, 2), '-', ...
             'Color', [0 0 0], 'LineWidth', 1.8, 'HandleVisibility', 'off');
    end
end

% LEGEND PROXIES. The real objects are a filled patch and a black line, and
% putting the patch itself in the legend would show a swatch of whichever
% region happened to be drawn first -- a colour that means a specific
% divergence value, not "boundary". Two NaN-data lines carry the styling into
% the legend without drawing anything on the map.
hBorder = plot(ax, NaN, NaN, '-', 'Color', BORDER, 'LineWidth', 0.8, ...
               'DisplayName', 'admin-2 region boundary');
hSouth  = plot(ax, NaN, NaN, '-', 'Color', [0 0 0], 'LineWidth', 1.8, ...
               'DisplayName', sprintf('Grand Sud (%s)', strjoin(cellstr(SOUTH), ', ')));

% ---- labels -------------------------------------------------------------
switch lower(string(opt.Labels))
    case "all"
        for iS = 1:numel(S)
            text(ax, S(iS).Longitude, S(iS).Latitude, sprintf('%+.3f', div(idx(iS))), ...
                 'FontSize', 7, 'HorizontalAlignment', 'center', ...
                 'Color', readableOn(fillCol(iS, :)));
        end
    case "south"
        for iS = 1:numel(S)
            if ~ismember(shpNames(iS), SOUTH); continue; end
            text(ax, S(iS).Longitude, S(iS).Latitude, ...
                 sprintf('%s\n%+.3f', shpNames(iS), div(idx(iS))), ...
                 'FontSize', 8, 'FontWeight', 'bold', ...
                 'HorizontalAlignment', 'center', ...
                 'Color', readableOn(fillCol(iS, :)));
        end
    case "none"
        % nothing
    otherwise
        error('make_divergence_map_panel:badLabels', ...
              'Labels must be ''south'', ''all'' or ''none''');
end

% ---- axis furniture -----------------------------------------------------
% One degree of longitude is cos(lat) of one degree of latitude on the
% ground. Leaving daspect at [1 1 1] would stretch the island east-west by
% about 6% at these latitudes.
allX = [S.X]; allY = [S.Y];
lat0 = mean([min(allY) max(allY)]);
mx = 0.02 * (max(allX) - min(allX));
my = 0.02 * (max(allY) - min(allY));
xlim(ax, [min(allX) - mx, max(allX) + mx]);
ylim(ax, [min(allY) - my, max(allY) + my]);
daspect(ax, [1 / cosd(lat0) 1 1]);
xlabel(ax, 'longitude (\circ)');
ylabel(ax, 'latitude (\circ)');
title(ax, sprintf(['SSP2-4.5 minus SSP5-8.5 crop yield factor at %d,\n' ...
                   'mean of the agricultural layers present in each region'], opt.Year), ...
      'FontWeight', 'normal');

cb = colorbar(ax);
cb.Label.String = sprintf('yield factor difference at %d', opt.Year);
cb.Label.FontSize = 9;

% LEGEND. The colourbar encodes the fill, so the legend exists to name the
% two line objects on the canvas -- otherwise a reader has no way to know
% what the heavy outline marks.
legend(ax, [hBorder hSouth], 'Location', 'southoutside', 'Box', 'off', ...
       'FontSize', 8);

if opt.Standalone && isempty(opt.Axes)
    if ~exist(fileparts(opt.OutFile), 'dir'); mkdir(fileparts(opt.OutFile)); end
    exportgraphics(fig, opt.OutFile, 'Resolution', 200);
    fprintf('Wrote %s\n', opt.OutFile);
end

% ---- numbers for the caption -------------------------------------------
isSouth = ismember(regNames, SOUTH);
natMean = mean(div);
sthMean = mean(div(isSouth));
[~, ord] = sort(div, 'descend');

fprintf('\n--- panel (b): SSP2 minus SSP5, layer-aware yield factor at %d ---\n', opt.Year);
fprintf('%-22s %8s %8s %9s  %s\n', 'region', 'SSP2', 'SSP5', 'diff', 'ag layers');
for iR = ord'
    fprintf('%-22s %8.3f %8.3f %+9.4f  %d%s\n', regNames(iR), Y2(iR, k), Y5(iR, k), ...
            div(iR), info.nLayersPerRegion(iR), ...
            repmat('   <- Grand Sud', 1, double(isSouth(iR))));
end
fprintf('\nnational mean %+0.4f   Grand Sud mean %+0.4f   ratio %.2fx\n', ...
        natMean, sthMean, sthMean / max(natMean, eps));
fprintf('range [%+0.4f, %+0.4f]\n', min(div), max(div));
ordNon = ord(~isSouth(ord));
nTop   = min(3, numel(ordNon));
fprintf(['CAUTION for the caption: the highest non-southern regions (%s) fall ' ...
         'inside the\nGrand Sud range, so "concentrated in the south" ' ...
         'overstates it. Androy is the outlier.\n'], ...
        strjoin(arrayfun(@(r) sprintf('%s %+0.3f', regNames(r), div(r)), ...
                         ordNon(1:nTop), 'UniformOutput', false), ', '));

out = struct('regNames', {cellstr(regNames)}, 'divergence', div, ...
             'ssp2', Y2(:, k), 'ssp5', Y5(:, k), 'year', opt.Year, ...
             'nationalMean', natMean, 'southMean', sthMean, ...
             'clim', [c0 c1], 'axes', ax);
end

% =========================================================================
function parts = splitOnNaN(x, y)
% Shapefile polygons store multiple rings separated by NaN. Each ring is
% returned as its own [x y] block so it can be patched independently.
x = x(:); y = y(:);
brk = [0; find(isnan(x)); numel(x) + 1];
parts = {};
for iB = 1:numel(brk) - 1
    seg = (brk(iB) + 1):(brk(iB + 1) - 1);
    if numel(seg) >= 3
        parts{end + 1} = [x(seg) y(seg)]; %#ok<AGROW>
    end
end
end

% =========================================================================
function cm = asymmetricDiverging(c0, c1, n)
% Blue-white-red with white pinned at zero rather than at the midpoint, so
% the limits can be asymmetric without moving the neutral reference. Blue and
% red are panel (a)'s SSP2 and SSP5 colours.
BLUE = [0.20 0.40 0.70];
RED  = [0.75 0.25 0.15];
W    = [1 1 1];

% Interpolate over the VALUE axis rather than over row index, so the white
% point lands exactly at zero instead of within one colour step of it.
v  = linspace(c0, c1, n)';
cm = zeros(n, 3);
neg = v < 0;
if any(neg)
    cm(neg, :) = interp1([c0; 0], [BLUE; W], v(neg));
end
if any(~neg)
    cm(~neg, :) = interp1([0; c1], [W; RED], v(~neg));
end
cm = min(max(cm, 0), 1);
end

% =========================================================================
function c = readableOn(bg)
% Black text on the saturated end of the red ramp is hard to read, and Androy
% -- the region a reader most wants to read -- sits there. Switch to white
% below a luminance threshold. Coefficients are Rec. 709.
lum = 0.2126 * bg(1) + 0.7152 * bg(2) + 0.0722 * bg(3);
if lum < 0.5
    c = [1 1 1];
else
    c = [0.1 0.1 0.1];
end
end

% =========================================================================
function setCLim(ax, lims)
% clim() replaced caxis() in R2022a; caxis still works but is discouraged.
if ~isempty(which('clim'))
    clim(ax, lims);
else
    caxis(ax, lims); %#ok<CAXIS>
end
end
