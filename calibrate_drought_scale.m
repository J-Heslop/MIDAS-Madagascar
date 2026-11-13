function [T, alphaRange] = calibrate_drought_scale(varargin)
% CALIBRATE_DROUGHT_SCALE  Identify droughtScaleFactor against reported yield losses.
%
%   [T, range] = calibrate_drought_scale
%   calibrate_drought_scale('SSP','SSP2','Plot',true)
%
% WHY THIS PARAMETER CANNOT BE CALIBRATED THE USUAL WAY
% droughtScaleFactor (alpha) converts a standardised drought index into a loss
% of crop yield. Doing that by composite scoring would require an observable
% the parameter nearly determines, and no such series exists: Madagascar has
% no crop-yield record at regional resolution over the calibration period.
% What does exist is a handful of documented events in which a drought of
% known severity produced a reported loss of known size. This identifies alpha
% directly from those events.
%
% THE ARITHMETIC
% In the model the yield factor in a given region, crop and year is
%
%     yF = clamp( Y0 + alpha * SPEI ,  floor , 1 )
%
% where Y0 is the GRMA secular yield factor and SPEI is the standardised
% index at that crop's sampling month. SPEI is standardised, so a normal year
% carries a perturbation of approximately zero and yF is approximately Y0.
% The fractional loss in a drought year, relative to a normal one, is
% therefore
%
%     loss = |alpha * SPEI| / Y0        and so       alpha = loss * Y0 / |SPEI|
%
% Each documented event gives one estimate. The spread across events is the
% identified range; it is not an error bar, because the events differ in
% severity, crop and region as well as in measurement.
%
% THREE BIASES, RUNNING IN BOTH DIRECTIONS. State these wherever the range is
% used; they are the reason it is reported as a range and not a value.
%
%   Production, not yield.  Reported losses are usually production, which is
%   area times yield. In a bad year farmers also plant less, so production
%   falls further than yield does. The model scales yield alone, so a
%   production-based loss OVERSTATES alpha.
%
%   Baseline drift.  The 2016 figure is a decline on 2015, which was itself a
%   poor year. Measured against a normal year the loss would be larger, so
%   using it as though it were a climatological comparison UNDERSTATES alpha.
%
%   Attribution.  Reported losses include everything that damaged the harvest.
%   FEWS NET records sandstorms in Ambovombe and fall armyworm in Ampanihy and
%   Amboasary alongside the 2021 drought, so some of that loss is not drought,
%   and attributing all of it OVERSTATES alpha.

p = inputParser;
p.addParameter('SSP','SSP2',@(x) ischar(x)||isstring(x));
p.addParameter('DataDir','./Data',@(x) ischar(x)||isstring(x));
p.addParameter('Plot',true,@islogical);
p.parse(varargin{:});
opt = p.Results; ssp = char(opt.SSP); dd = char(opt.DataDir);

% ---------------------------------------------------------------- events
% region | crop | year | loss low | loss high | source
% Losses are fractions of a normal harvest. Add rows as further events are
% documented; the arithmetic below does not change.
EV = { ...
 'Androy',           'maize',   2016, 0.80, 0.80, 'FAO/GIEWS (2016): maize production in Androy 80% below 2015';
 'Androy',           'maize',   2021, 0.50, 0.70, 'FEWS NET (2021): southern production 50-70% below the five-year average';
 'Anosy',            'maize',   2021, 0.50, 0.70, 'FEWS NET (2021), as above';
 'Atsimo-Andrefana', 'maize',   2021, 0.50, 0.70, 'FEWS NET (2021), as above';
 'Androy',           'cassava', 2021, 0.50, 0.70, 'FEWS NET (2021), as above';
};

nE = size(EV,1);
region = EV(:,1); crop = EV(:,2);
year = cell2mat(EV(:,3)); lossLo = cell2mat(EV(:,4)); lossHi = cell2mat(EV(:,5));
src = EV(:,6);
spei = nan(nE,1); Y0 = nan(nE,1); aLo = nan(nE,1); aHi = nan(nE,1);

speiFile = fullfile(dd,'observed_spei_harvest.csv');
if ~exist(speiFile,'file')
    error('calibrate_drought_scale:noSpei','Not found: %s', speiFile);
end
S = readtable(speiFile,'TextType','string','VariableNamingRule','preserve');

for i = 1:nE
    % SPEI-6 at that crop's own sampling month, as the model uses it
    scol = sprintf('%s_y%d', crop{i}, year(i));
    spei(i) = lookup(S, region{i}, scol, speiFile);

    % GRMA secular yield factor for the same region, crop and year
    yFile = fullfile(dd, sprintf('GRMA_yield_%s_%s.csv', crop{i}, ssp));
    if ~exist(yFile,'file')
        error('calibrate_drought_scale:noYield','Not found: %s', yFile);
    end
    Ytbl = readtable(yFile,'TextType','string','VariableNamingRule','preserve');
    Y0(i) = lookup(Ytbl, region{i}, sprintf('y%d', year(i)), yFile);

    if spei(i) >= 0
        warning('calibrate_drought_scale:notDrought', ...
                ['%s %s %d has SPEI %+.2f, i.e. not a drought at that crop''s ' ...
                 'sampling month. Excluded.'], region{i}, crop{i}, year(i), spei(i));
        continue;
    end
    aLo(i) = lossLo(i) * Y0(i) / abs(spei(i));
    aHi(i) = lossHi(i) * Y0(i) / abs(spei(i));
end

T = table(string(region), string(crop), year, spei, Y0, lossLo, lossHi, aLo, aHi, string(src), ...
    'VariableNames', {'region','crop','year','spei6','grmaY0','lossLow','lossHigh', ...
                      'alphaLow','alphaHigh','source'});

all = [aLo; aHi]; all = all(~isnan(all));
alphaRange = [min(all) max(all)];

% The range actually carried into the model excludes Atsimo-Andrefana 2021 on
% the spatial-scale grounds set out below. Compute it HERE rather than leaving
% it to be reconstructed from the printout: the difference between the pooled
% and the carried range is a judgement call, and a judgement call that has to
% be re-derived by hand every time it is questioned will eventually be
% re-derived wrongly.
isExcl = strcmp(region, 'Atsimo-Andrefana') & year == 2021;
kept   = [aLo(~isExcl); aHi(~isExcl)]; kept = kept(~isnan(kept));
alphaCarried = [min(kept) max(kept)];

fprintf('\n=== droughtScaleFactor identified from documented events ===\n');
fprintf('%-18s %-9s %5s %7s %7s %12s %15s\n','region','crop','year','SPEI-6','GRMA Y0','loss','alpha');
fprintf('%s\n', repmat('-',1,78));
for i = 1:nE
    if isnan(aLo(i)); continue; end
    fprintf('%-18s %-9s %5d %+7.2f %7.3f %6.2f-%-5.2f %7.3f-%.3f\n', ...
        region{i}, crop{i}, year(i), spei(i), Y0(i), lossLo(i), lossHi(i), aLo(i), aHi(i));
end
fprintf('\nPooled range %.2f to %.2f, midpoint %.2f, median of endpoints %.2f.\n', ...
        alphaRange(1), alphaRange(2), mean(alphaRange), median(all));
fprintf(['\nThe upper end rests on Atsimo-Andrefana in 2021, where the sampling-month\n' ...
         'SPEI was only %+.2f against %.2f and %.2f in the other two southern regions.\n' ...
         'A regional loss figure applied to the least drought-affected of the three\n' ...
         'forces alpha up to compensate. Treat the top of the range with that in mind.\n'], ...
        spei(strcmp(region,'Atsimo-Andrefana') & year==2021), ...
        spei(strcmp(region,'Androy') & year==2021 & strcmp(crop,'maize')), ...
        spei(strcmp(region,'Anosy') & year==2021));

fprintf(['\nRANGE CARRIED INTO THE MODEL: %.2f to %.2f (Atsimo-Andrefana 2021 excluded).\n' ...
         'Pooled across all %d events it would be %.2f to %.2f. The whole of that\n' ...
         'difference is the one event, so the exclusion is not a trimming rule --\n' ...
         'it is a single decision that must be stated wherever the range is quoted.\n' ...
         'The upper end, %.3f, is Androy maize 2016 measured directly.\n'], ...
        alphaCarried(1), alphaCarried(2), sum(~isnan(aLo)), ...
        alphaRange(1), alphaRange(2), alphaCarried(2));
if abs(alphaCarried(2) - 0.42) > 0.01 || abs(alphaCarried(1) - 0.25) > 0.01
    fprintf(2, ['\n[CHECK] The carried range no longer matches the [0.25, 0.42] hard-coded\n' ...
                '        in the declaredRange block of runMIDASExperiment_parallel.m.\n' ...
                '        Update the runner, or the projections sample a range this\n' ...
                '        script no longer supports.\n']);
end

if opt.Plot
    f = figure('Color','w','Position',[100 100 760 380]);
    ax = axes(f); hold(ax,'on'); box(ax,'on');
    lbl = strings(nE,1);
    for i = 1:nE
        lbl(i) = sprintf('%s %s %d', region{i}, crop{i}, year(i));
        if isnan(aLo(i)); continue; end
        plot(ax,[aLo(i) aHi(i)],[i i],'-','Color',[0.30 0.45 0.70],'LineWidth',6);
        plot(ax,mean([aLo(i) aHi(i)]), i, 'o','MarkerFaceColor','w', ...
             'MarkerEdgeColor',[0.20 0.30 0.50],'LineWidth',1.2);
    end
    xr = xline(ax, alphaRange, '--', 'Color',[0.45 0.45 0.45]);
    set(ax,'YTick',1:nE,'YTickLabel',lbl,'YLim',[0.4 nE+0.6],'FontSize',9);
    xlabel(ax,'droughtScaleFactor (\alpha) implied by the event');
    title(ax, sprintf('Identification of \\alpha from documented yield losses (pooled %.2f-%.2f)', ...
          alphaRange(1), alphaRange(2)), 'FontWeight','bold','FontSize',10);
    grid(ax,'on'); ax.GridAlpha = 0.12;
    png = fullfile(dd,'..','fig_alpha_identification.png');
    exportgraphics(f, png, 'Resolution', 200);
    fprintf('\nWrote %s\n', png);
end
end

% =========================================================================
function v = lookup(T, regionName, colName, fileName)
% Match on a normalised region name: the CSVs differ on hyphens and
% apostrophes between sources, and a silent no-match here would return an
% empty and propagate as NaN into the calibration.
norm = @(s) lower(regexprep(string(s),'[^A-Za-z]',''));
names = T.(T.Properties.VariableNames{1});
idx = find(norm(names) == norm(regionName));
if isempty(idx)
    error('calibrate_drought_scale:noRegion', ...
          'Region "%s" not found in %s', regionName, fileName);
end
if ~ismember(colName, T.Properties.VariableNames)
    error('calibrate_drought_scale:noColumn', ...
          'Column "%s" not found in %s', colName, fileName);
end
v = double(T.(colName)(idx(1)));
end
