import fs from "node:fs/promises";
import path from "node:path";
import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const inputPath = process.env.INPUT_PATH
  || "/Users/yacti/Downloads/game_balance_sheet2-2_golden_pretty_seed_rollchance_sorted.xlsx";
const outputDir = "/Users/yacti/my-game/outputs/019f980d-49ae-7063-8d1b-60461be73290";
const previewDir = "/Users/yacti/my-game/previews/balance-review";

const input = await FileBlob.load(inputPath);
const workbook = await SpreadsheetFile.importXlsx(input);

if (process.env.APPLY_EDITS === "1") {
  const feeds = workbook.worksheets.getItem("Feeds");
  const pets = workbook.worksheets.getItem("Pets");
  const seeds = workbook.worksheets.getItem("Seeds");
  const assumptions = workbook.worksheets.getItem("Assumptions");
  const luckUpgrades = workbook.worksheets.getItem("LuckUpgrades");
  const readme = workbook.worksheets.getItem("README");
  const exportSummary = workbook.worksheets.getItem("Export Summary");

  exportSummary.getRange("B7:D7").format = {
    fill: "#E2E8F0",
    font: { bold: true, color: "#0F172A" },
  };
  exportSummary.getRange("B9:D24").format = {
    fill: "#FFFFFF",
    font: { color: "#0F172A" },
  };

  const replacementFeeds = [
    ["GoldenmelonPatch", "Patch", 50000, 1, "Golden pet progression: Unicorn transition + Golden Chicken-Cow"],
    ["GoldenCactus", "Tree", 125000, null, "Golden pet progression: Golden Bull-Snail"],
    ["GoldenFigTree", "Tree", 300000, null, "Golden pet progression: Golden Crab-Elephant"],
    ["GoldenDragonfruitTree", "Tree", 750000, null, "Golden pet progression: Golden Bear-Hydra"],
    ["GoldshroomPatch", "Patch", 2000000, 1, "Golden pet progression: Golden Ankylosaurus-Unicorn"],
  ];
  const feedRows = feeds.getRange("A2:F26").values.map((row) => [...row]);
  const appleTreeRow = feedRows.find((row) => row[0] === "AppleTree");
  if (appleTreeRow) {
    appleTreeRow[3] = null;
  }
  for (let index = 0; index < replacementFeeds.length; index += 1) {
    const [feedType, feedClass, xp, growRate, notes] = replacementFeeds[index];
    feedRows[feedRows.length - replacementFeeds.length + index] = [
      feedType,
      feedClass,
      xp,
      growRate,
      null,
      notes,
    ];
  }
  feeds.getRange("A2:D26").values = feedRows.map((row) => row.slice(0, 4));
  feeds.getRange("E2:E26").formulas = feedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=IF(B${rowNumber}="Patch",C${rowNumber}*60/D${rowNumber},C${rowNumber}*'Assumptions'!$B$3*60)`];
  });
  feeds.getRange("F2:F26").values = feedRows.map((row) => [row[5]]);

  const petRows = pets.getRange("A2:J107").values.map((row) => [...row]);
  const correctedPetNames = new Map([
    ["Pet3", "Guinea Pig"],
    ["Pet15", "Golden Retriever"],
    ["Pet31", "Giraffe"],
    ["Pet46", "Velociraptor"],
    ["Pet56", "Golden Guinea Pig"],
    ["Pet84", "Golden Giraffe"],
    ["Pet99", "Golden Velociraptor"],
  ]);
  for (const row of petRows) {
    const order = Number(row[0]);
    const petId = String(row[1]);
    if (correctedPetNames.has(petId)) {
      row[2] = correctedPetNames.get(petId);
    }
    if (order >= 53 && order <= 64) {
      row[6] = "GoldenmelonPatch";
    } else if (order >= 65 && order <= 74) {
      row[6] = "GoldenCactus";
    } else if (order >= 75 && order <= 85) {
      row[6] = "GoldenFigTree";
    } else if (order >= 86 && order <= 95) {
      row[6] = "GoldenDragonfruitTree";
    } else if (order >= 96 && order <= 106) {
      row[6] = "GoldshroomPatch";
    }
  }
  pets.getRange("C2:C107").values = petRows.map((row) => [row[2]]);
  pets.getRange("G2:G107").values = petRows.map((row) => [row[6]]);
  pets.getRange("H2:H107").formulas = petRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=IF(G${rowNumber}="","",VLOOKUP(G${rowNumber},'Feeds'!$A$2:$E$26,5,FALSE))`];
  });
  pets.getRange("I2:I107").formulas = petRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=IF(OR(F${rowNumber}="",H${rowNumber}=""),"",ROUND(F${rowNumber}/H${rowNumber},1))`];
  });

  const growTimeBySeedId = new Map([
    ["AppleTreeSeed", 3],
    ["PumpkinSeed", 3],
    ["CabbageSeed", 3],
    ["PotatoSeed", 3],
    ["OrangeTreeSeed", 60],
    ["WatermelonSeed", 3],
    ["PlumTreeSeed", 120],
    ["CornSeed", 3],
    ["CherryTreeSeed", 420],
    ["MushroomSeed", 3],
    ["BananaTreeSeed", 900],
    ["CactusSeed", 1200],
    ["PineappleSeed", 3],
    ["FigTreeSeed", 3600],
    ["PurpleShroomSeed", 3],
    ["BloodOrangeTreeSeed", 5400],
    ["GlowshroomSeed", 3],
    ["DragonfruitTreeSeed", 12600],
    ["GoldenAppleTreeSeed", 16200],
    ["DurianTreeSeed", 21600],
    ["GoldenmelonSeed", 3],
    ["GoldenCactusSeed", 28800],
    ["GoldenFigTreeSeed", 36000],
    ["GoldenDragonfruitSeed", 43200],
    ["GoldshroomSeed", 3],
  ]);
  const seedValues = seeds.getRange("A2:M26").values;
  const seedFormulas = seeds.getRange("A2:M26").formulas;
  const seedRows = seedValues.map((row, index) => ({
    seedId: row[0],
    displayName: row[1],
    feedType: row[2],
    rarity: row[3],
    rollChanceN: row[4],
    matchedPetId: row[6],
    minutesRequired: row[9],
    minutesFormula: seedFormulas[index][9],
    currentPrice: row[11],
    growTimeSeconds: growTimeBySeedId.get(String(row[0])),
  }));

  for (const row of seedRows) {
    if (row.seedId === "GoldenmelonSeed") {
      row.displayName = "Goldenmelon Seed";
      row.feedType = "GoldenmelonPatch";
    } else if (row.seedId === "GoldenCactusSeed") {
      row.displayName = "Golden Cactus Seed";
    } else if (row.seedId === "GoldshroomSeed") {
      row.feedType = "GoldshroomPatch";
    }
  }

  const rarityOrder = new Map([
    ["Common", 1],
    ["Rare", 2],
    ["Epic", 3],
    ["Legendary", 4],
    ["Mythical", 5],
    ["Secret", 6],
    ["Exclusive", 7],
  ]);
  seedRows.sort((left, right) => {
    const rarityDelta = (rarityOrder.get(left.rarity) ?? 999) - (rarityOrder.get(right.rarity) ?? 999);
    if (rarityDelta !== 0) return rarityDelta;
    const chanceDelta = Number(left.rollChanceN) - Number(right.rollChanceN);
    if (chanceDelta !== 0) return chanceDelta;
    return String(left.seedId).localeCompare(String(right.seedId));
  });

  seeds.getRange("A2:E26").values = seedRows.map((row) => [
    row.seedId,
    row.displayName,
    row.feedType,
    row.rarity,
    row.rollChanceN,
  ]);
  seeds.getRange("F2:F26").formulas = seedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`="1 in "&TEXT(E${rowNumber},"#,##0")`];
  });
  seeds.getRange("G2:G26").values = seedRows.map((row) => [row.matchedPetId]);
  seeds.getRange("H2:H26").formulas = seedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=VLOOKUP(G${rowNumber},'Pets'!$B$2:$E$107,2,FALSE)`];
  });
  seeds.getRange("I2:I26").formulas = seedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=VLOOKUP(G${rowNumber},'Pets'!$B$2:$E$107,4,FALSE)`];
  });
  seeds.getRange("J2:J26").values = seedRows.map((row) => [
    row.minutesFormula ? null : row.minutesRequired,
  ]);
  seedRows.forEach((row, index) => {
    if (row.minutesFormula) {
      seeds.getRange(`J${index + 2}`).formulas = [[row.minutesFormula]];
    }
  });
  seeds.getRange("K2:K26").formulas = seedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=I${rowNumber}*60*J${rowNumber}`];
  });
  seeds.getRange("L2:L26").values = seedRows.map((row) => [row.currentPrice]);
  seeds.getRange("M2:M26").formulas = seedRows.map((_, index) => {
    const rowNumber = index + 2;
    return [`=L${rowNumber}-K${rowNumber}`];
  });
  seeds.getRange("N1:N26").copyFrom(seeds.getRange("M1:M26"), "all");
  seeds.getRange("N1").values = [["GrowTimeSeconds"]];
  seeds.getRange("N2:N26").values = seedRows.map((row) => [row.growTimeSeconds]);
  seeds.getRange("N1:N26").format.borders = {
    preset: "all",
    style: "thin",
    color: "#0000FF",
  };
  seeds.getRange("N1").format.font = { bold: true, color: "#000000" };
  seeds.getRange("N2:N26").format.numberFormat = "#,##0";
  seeds.getRange("N1:N26").format.columnWidth = 18;
  readme.getRange("A7").values = [[
    "Seeds: roll rarity/chance/price, grow time, plus formula price helpers.",
  ]];

  assumptions.getRange("A5:C5").values = [[
    "GoldenCapIncomePerSecond",
    13500,
    "Golden Unicorn (Pet106) income used for late-game upgrade hour estimates.",
  ]];
  assumptions.getRange("A9:C14").values = [
    ["GoldenEntryIncomePerSecond", 8100, "Golden Ankylosaurus (Pet96), the first Goldshroom-tier pet."],
    ["LuckLegacyMaxLevel", 100, "Existing luck levels and prices remain unchanged through this level."],
    ["LuckPercentPerLevel", 5, "Every luck upgrade adds five percentage points through level 200."],
    ["LuckLatePriceExponent", 4, "Late-game prices scale from the level-100 price by (level / 100)^exponent."],
    ["LuckLatePriceRounding", 100000, "Late-game prices round to the nearest currency increment."],
    ["LuckLateMaxPriceMultiplier", 3, "Price multiplier increases linearly from 1x at level 100 to this cap at level 200."],
  ];
  assumptions.getRange("A9:E14").format.borders = {
    preset: "all",
    style: "thin",
    color: "#0000FF",
  };
  assumptions.getRange("B5:B14").format.numberFormat = "#,##0";

  const legacyLuckPrices = luckUpgrades.getRange("D2:D101").values.map((row) => [row[0]]);
  luckUpgrades.getRange("A1:I201").clear({ applyTo: "all" });
  luckUpgrades.getRange("A1:I1").values = [[
    "Level",
    "LuckPercent",
    "EffectiveLuckMultiplier",
    "LatePriceMultiplier",
    "RawFormulaPrice",
    "CurrentPrice",
    "CumulativePrice",
    "CumulativeHoursAtGoldenEntry",
    "CumulativeHoursAtGoldenCap",
  ]];
  luckUpgrades.getRange("A2:A201").values = Array.from(
    { length: 200 },
    (_, index) => [index + 1],
  );
  luckUpgrades.getRange("B2:B201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=A${rowNumber}*'Assumptions'!$B$11`];
    },
  );
  luckUpgrades.getRange("C2:C201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=1+B${rowNumber}/100`];
    },
  );
  luckUpgrades.getRange("D2:D201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=IF(A${rowNumber}<='Assumptions'!$B$10,1,1+('Assumptions'!$B$14-1)*(A${rowNumber}-'Assumptions'!$B$10)/(MAX($A$2:$A$201)-'Assumptions'!$B$10))`];
    },
  );
  luckUpgrades.getRange("E2:E201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=IF(A${rowNumber}<='Assumptions'!$B$10,'Assumptions'!$B$6*A${rowNumber}^2*(1+'Assumptions'!$B$7*(A${rowNumber}/'Assumptions'!$B$10)^'Assumptions'!$B$8),$F$101*(A${rowNumber}/'Assumptions'!$B$10)^'Assumptions'!$B$12*D${rowNumber})`];
    },
  );
  luckUpgrades.getRange("F2:F101").values = legacyLuckPrices;
  luckUpgrades.getRange("F102:F201").formulas = Array.from(
    { length: 100 },
    (_, index) => {
      const rowNumber = index + 102;
      return [`=ROUND(E${rowNumber}/'Assumptions'!$B$13,0)*'Assumptions'!$B$13`];
    },
  );
  luckUpgrades.getRange("G2:G201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=SUM($F$2:F${rowNumber})`];
    },
  );
  luckUpgrades.getRange("H2:H201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=G${rowNumber}/'Assumptions'!$B$9/3600`];
    },
  );
  luckUpgrades.getRange("I2:I201").formulas = Array.from(
    { length: 200 },
    (_, index) => {
      const rowNumber = index + 2;
      return [`=G${rowNumber}/'Assumptions'!$B$5/3600`];
    },
  );
  luckUpgrades.getRange("A1:I201").format.borders = {
    preset: "all",
    style: "thin",
    color: "#0000FF",
  };
  luckUpgrades.getRange("A1:I1").format.font = { bold: true, color: "#000000" };
  luckUpgrades.getRange("A2:B201").format.numberFormat = "#,##0";
  luckUpgrades.getRange("C2:D201").format.numberFormat = "0.00\"x\"";
  luckUpgrades.getRange("E2:G201").format.numberFormat = "#,##0";
  luckUpgrades.getRange("H2:I201").format.numberFormat = "0.00";
  for (const [range, width] of [
    ["A:A", 10],
    ["B:B", 16],
    ["C:C", 22],
    ["D:D", 20],
    ["E:G", 20],
    ["H:I", 30],
  ]) {
    luckUpgrades.getRange(range).format.columnWidth = width;
  }
  luckUpgrades.freezePanes.freezeRows(1);
  readme.getRange("A8").values = [[
    "LuckUpgrades: 200 levels in 5% steps, reaching 1000% luck; levels 101-200 ramp from a 1x to 3x late-price multiplier.",
  ]];

  const reviewedOutput = path.join(
    outputDir,
    "game_balance_sheet2-2_golden_pretty_seed_rollchance_sorted_reviewed.xlsx",
  );
  const reviewedPreviewDir = path.join(previewDir, "reviewed");
  await fs.mkdir(reviewedPreviewDir, { recursive: true });
  for (const sheetName of [
    "Export Summary",
    "README",
    "Assumptions",
    "Feeds",
    "Pets",
    "Seeds",
    "LuckUpgrades",
    "RollPads",
    "Rebirths",
  ]) {
    const render = await workbook.render({
      sheetName,
      autoCrop: "all",
      scale: 1,
      format: "png",
    });
    const safeName = sheetName.replace(/[^A-Za-z0-9_-]+/g, "_");
    await fs.writeFile(
      path.join(reviewedPreviewDir, `${safeName}.png`),
      new Uint8Array(await render.arrayBuffer()),
    );
  }

  const keyRanges = {};
  for (const [sheetName, range] of [
    ["Feeds", "A1:F26"],
    ["Pets", "A50:J107"],
    ["Seeds", "A1:N26"],
    ["LuckUpgrades", "A1:I201"],
  ]) {
    const check = await workbook.inspect({
      kind: "table",
      range: `${sheetName}!${range}`,
      include: "values,formulas",
      tableMaxRows: 220,
      tableMaxCols: 15,
      maxChars: 30000,
    });
    keyRanges[sheetName] = check.ndjson;
  }
  const formulaErrors = await workbook.inspect({
    kind: "match",
    searchTerm: "#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A",
    options: { useRegex: true, maxResults: 300 },
    summary: "reviewed workbook formula error scan",
  });
  const output = await SpreadsheetFile.exportXlsx(workbook);
  await output.save(reviewedOutput);
  console.log(JSON.stringify({
    reviewedOutput,
    formulaErrors: formulaErrors.ndjson,
    keyRanges,
  }));
  process.exit(0);
}

const focusSheet = process.env.FOCUS_SHEET;
if (process.env.MANIFEST_ONLY === "1" && focusSheet) {
  const sheet = workbook.worksheets.getItem(focusSheet);
  const target = sheet.getUsedRange();
  console.log(JSON.stringify({
    exactSheet: focusSheet,
    values: target.values,
    formulas: process.env.VALUES_ONLY === "1" ? undefined : target.formulas,
  }));
  process.exit(0);
}

const overview = await workbook.inspect({
  kind: "sheet",
  include: "id,name",
  maxChars: 8000,
});
console.log(overview.ndjson);

const sheetRecords = overview.ndjson
  .split("\n")
  .filter(Boolean)
  .map((line) => {
    try {
      return JSON.parse(line);
    } catch {
      return null;
    }
  })
  .filter((record) => record && typeof record.name === "string" && String(record.id || "").startsWith("ws/"));

const selectedSheetRecords = focusSheet
  ? sheetRecords.filter((record) => record.name === focusSheet)
  : sheetRecords;

await fs.mkdir(previewDir, { recursive: true });
for (const record of selectedSheetRecords) {
  if (focusSheet) {
    const sheet = workbook.worksheets.getItem(record.name);
    const target = sheet.getRange(record.range);
    console.log(JSON.stringify({
      exactSheet: record.name,
      range: record.range,
      values: target.values,
      formulas: target.formulas,
    }));
  }

  const render = await workbook.render({
    sheetName: record.name,
    autoCrop: "all",
    scale: 1,
    format: "png",
  });
  const safeName = record.name.replace(/[^A-Za-z0-9_-]+/g, "_");
  await fs.writeFile(
    path.join(previewDir, `${safeName}.png`),
    new Uint8Array(await render.arrayBuffer()),
  );

  const region = await workbook.inspect({
    kind: "region",
    sheetId: record.name,
    range: record.range || "A1:Z120",
    maxChars: 35000,
    tableMaxRows: 220,
    tableMaxCols: 30,
    tableMaxCellChars: 120,
  });
  console.log(JSON.stringify({ sheet: record.name, region: region.ndjson }));

  if (record.name === "Seeds" || record.name === "Feeds" || record.name === "Pets") {
    const targetRange = record.range || "A1:Z220";
    const formulas = await workbook.inspect({
      kind: "formula",
      sheetId: record.name,
      range: targetRange,
      maxChars: 12000,
      options: { maxResults: 300 },
    });
    const styles = await workbook.inspect({
      kind: "computedStyle",
      sheetId: record.name,
      range: targetRange,
      maxChars: 8000,
    });
    console.log(JSON.stringify({ sheet: record.name, formulas: formulas.ndjson }));
    console.log(JSON.stringify({ sheet: record.name, styles: styles.ndjson }));
  }
}
