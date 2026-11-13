function [Y, regNames, years, info] = grmaLayerMeanYield(ssp, varargin)
% grmaLayerMeanYield  --  the SECULAR component of agYF, per region and year
%
%   Y = grmaLayerMeanYield('SSP2')
%   [Y, regNames, years, info] = grmaLayerMeanYield('SSP5', 'EndYear', 2085)
%
% WHAT IT RETURNS
% Y is nRegions x nYears: the mean GRMA yield factor across the
% drought-sensitive agricultural layers ACTUALLY AVAILABLE in each region.
%
% WHY THIS EXISTS
% createUtilityLayers builds agYF as
%
%     availAg = grmaLayerIdx(~spatiallyRestricted(iLoc, grmaLayerIdx));
%     agYF(iLoc, iCyc) = mean(yieldFactor(iLoc, availAg, iCyc));
%
% i.e. the mean over the ag layers present at that location, not over all
% crops. utility_layers_v1.csv restricts rice to two disjoint region sets:
%
%     rice_north  Diana, Sava, Sofia, Analanjirofo, Alaotra-Mangoro
%     rice_south  Amoron'i mania, Haute matsiatra, Vatovavy Fitovinany,
%                 Atsimo-Atsinana, Ihorombe, Analamanga, Bongolava, Itasy,
%                 Vakinankaratra
%
% Eight regions appear in NEITHER list -- Androy, Anosy, Atsimo-Andrefana,
% Menabe, Betsiboka, Boeny, Melaky, Atsinanana -- so they have maize and
% cassava only. All three Grand Sud regions are in that group.
%
% A figure that averages rice, maize and cassava uniformly therefore plots a
% quantity the model never computes, and does so most wrongly in exactly the
% regions the paper is about. Both panel (a) and the divergence map call this
% function so they cannot drift apart from each other or from the model.
%
% WHAT IS AND IS NOT INCLUDED
% This is the SECULAR trajectory only: the GRMA surfaces as read from disk.
% It carries no Markov drought realisation and no per-layer floor, because
% floors clamp the PERTURBED value (see the min/max in createUtilityLayers)
% and leave the underlying trend untouched. So Y is the scenario signal with
% interannual variability removed -- which is what a scenario-divergence
% figure should show, and what makes the map reproducible without a run.
%
% MATCHING RULE
% createUtilityLayers resolves restrict_to with
%     ismember(locNameVec, strsplit(restrictTo(iL), '|'))
% -- exact, case-sensitive string equality. This function does the same, and
% errors rather than warns if a layer matches no region, because a silent
% mismatch here reproduces the truncated-name class of bug that already cost
% this project two drought-free study regions.

p = inputParser;
addParameter(p, 'DataDir',   './Data');
addParameter(p, 'LayerFile', './Data/utility_layers_v1.csv');
addParameter(p, 'EndYear',   2085);
parse(p, varargin{:});
opt = p.Results;

% ---- layer definitions --------------------------------------------------
L = readtable(opt.LayerFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
for f = {'name', 'restrict_to', 'grma_crop'}
    if ~ismember(f{1}, L.Properties.VariableNames)
        error('grmaLayerMeanYield:badLayerFile', ...
              '%s has no "%s" column', opt.LayerFile, f{1});
    end
end

% Drought-sensitive ag layers are those carrying a grma_crop. industrial_crop
% was deliberately blanked (it is a wage, decoupled from direct yield) and
% vanilla never had one, so both are correctly excluded here.
% Guard against readtable typing an all-blank column as double NaN.
if ~isstring(L.grma_crop); L.grma_crop = string(L.grma_crop); end
isAg = strlength(strtrim(L.grma_crop)) > 0;
isAg(ismissing(L.grma_crop)) = false;
agIdx = find(isAg);
if isempty(agIdx)
    error('grmaLayerMeanYield:noAgLayers', ...
          'no layer in %s carries a grma_crop', opt.LayerFile);
end

% ---- read one surface to fix the region list and year axis --------------
firstFile = fullfile(opt.DataDir, ...
    sprintf('GRMA_yield_%s_%s.csv', L.grma_crop(agIdx(1)), ssp));
if ~exist(firstFile, 'file')
    error('grmaLayerMeanYield:missingSurface', 'missing %s', firstFile);
end
T0 = readtable(firstFile, 'TextType', 'string');
regNames = strtrim(string(T0{:, 1}));
nReg = numel(regNames);
allYears = 1985 + (0:(width(T0) - 2));
keep = allYears <= opt.EndYear;
years = allYears(keep);
nYr = numel(years);

% ---- availability, mirroring createUtilityLayers ------------------------
avail = true(nReg, numel(agIdx));
for k = 1:numel(agIdx)
    iL = agIdx(k);
    if L.restrict_to(iL) ~= "ALL"
        % split() rather than strsplit(): with a string scalar it returns a
        % string array unambiguously, so ismember against regNames (also a
        % string array) cannot fall into cellstr/char comparison.
        allowed = strtrim(split(L.restrict_to(iL), "|"));
        hit = ismember(regNames, allowed);
        if ~any(hit)
            error('grmaLayerMeanYield:noRegionMatch', ...
                  ['layer "%s" restrict_to="%s" matched 0 of %d regions. ' ...
                   'Exact, case-sensitive match is required -- check spelling ' ...
                   'against the GRMA surface region names.'], ...
                  L.name(iL), L.restrict_to(iL), nReg);
        end
        avail(:, k) = hit;
    end
end

% Every region must retain at least one ag layer, or agYF falls back to 1 --
% a drought-free region, which is the failure mode this project has already
% been bitten by twice. Say so loudly rather than returning ones().
noAg = find(~any(avail, 2));
if ~isempty(noAg)
    error('grmaLayerMeanYield:regionWithoutAg', ...
          ['%d region(s) have no agricultural layer at all: %s. agYF would ' ...
           'be 1 (no drought effect) there.'], ...
          numel(noAg), strjoin(cellstr(regNames(noAg)), ', '));
end

% ---- read the surfaces --------------------------------------------------
% Positional access (column 1 = region name, 2:end = y1985..) mirrors
% createUtilityLayers, so header renaming by readtable cannot break it.
S = nan(nReg, nYr, numel(agIdx));
for k = 1:numel(agIdx)
    iL = agIdx(k);
    f = fullfile(opt.DataDir, sprintf('GRMA_yield_%s_%s.csv', L.grma_crop(iL), ssp));
    if ~exist(f, 'file')
        error('grmaLayerMeanYield:missingSurface', ...
              'layer "%s" needs %s, which is missing', L.name(iL), f);
    end
    T = readtable(f, 'TextType', 'string');
    rn = strtrim(string(T{:, 1}));
    if ~isequal(rn, regNames)
        error('grmaLayerMeanYield:regionOrderMismatch', ...
              ['%s lists regions in a different order or set than %s. These ' ...
               'are indexed positionally; aborting rather than mismatching ' ...
               'regions to yields.'], f, firstFile);
    end
    yd = table2array(T(:, 2:end));
    S(:, :, k) = yd(:, keep);
end

% ---- layer mean, restrictions respected ---------------------------------
Y = nan(nReg, nYr);
for iR = 1:nReg
    use = avail(iR, :);
    Y(iR, :) = mean(S(iR, :, use), 3, 'omitnan');
end

info = struct('layerNames', {cellstr(L.name(agIdx))}, ...
              'crops', {cellstr(L.grma_crop(agIdx))}, ...
              'available', avail, 'ssp', ssp, ...
              'nLayersPerRegion', sum(avail, 2));
end
