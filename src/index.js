require('dotenv').config();
const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.json());

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;
const supabase = createClient(supabaseUrl, supabaseKey);

// -----------------------------------------------------------------------------
// INFRAESTRUTURA & STATUS
// -----------------------------------------------------------------------------
app.get('/status', async (req, res) => {
  const { data: rules, error } = await supabase.from('policy_rules').select('*');
  if (error) return res.status(500).json({ status: 'error', error: error.message });
  res.json({ status: 'online', active_policies: rules });
});

// -----------------------------------------------------------------------------
// POLICY ENGINE: GESTÃO DINÂMICA DE REGRAS (CRUD)
// -----------------------------------------------------------------------------

app.get('/api/policies', async (req, res) => {
  const { data, error } = await supabase
    .from('policy_rules')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) return res.status(500).json({ error: error.message });
  return res.json({ success: true, policies: data });
});

app.post('/api/policies', async (req, res) => {
  const { rule_name, is_active, parameters } = req.body;

  if (!rule_name) {
    return res.status(400).json({ error: 'O nome da regra (rule_name) é obrigatório.' });
  }

  const { data, error } = await supabase
    .from('policy_rules')
    .insert([{ 
      rule_name, 
      is_active: is_active ?? true, 
      parameters: parameters || {} 
    }])
    .select();

  if (error) return res.status(400).json({ error: error.message });
  return res.status(201).json({ success: true, policy: data[0] });
});

app.patch('/api/policies/:id', async (req, res) => {
  const { id } = req.params;
  const { is_active, parameters } = req.body;

  const updateData = {};
  if (typeof is_active === 'boolean') updateData.is_active = is_active;
  if (parameters) updateData.parameters = parameters;

  const { data, error } = await supabase
    .from('policy_rules')
    .update(updateData)
    .eq('id', id)
    .select();

  if (error) return res.status(400).json({ error: error.message });
  if (!data || data.length === 0) return res.status(404).json({ error: 'Regra não encontrada.' });

  return res.json({ success: true, policy: data[0] });
});

app.delete('/api/policies/:id', async (req, res) => {
  const { id } = req.params;

  const { data, error } = await supabase
    .from('policy_rules')
    .update({ is_active: false })
    .eq('id', id)
    .select();

  if (error) return res.status(400).json({ error: error.message });
  return res.json({ success: true, message: 'Regra desativada com sucesso.', policy: data[0] });
});

// -----------------------------------------------------------------------------
// LEDGER: PROCESSAMENTO DE TRANSAÇÕES COM VALIDAÇÃO DINÂMICA DE POLITICAS
// -----------------------------------------------------------------------------
app.post('/api/ledger/transaction', async (req, res) => {
  const { wallet_id, amount, operation_type, description } = req.body;

  try {
    const { data: wallet, error: walletErr } = await supabase
      .from('wallets')
      .select('*')
      .eq('id', wallet_id)
      .single();

    if (walletErr || !wallet) {
      return res.status(404).json({ error: 'Carteira não encontrada.' });
    }

    const currentBalance = parseFloat(wallet.balance);
    const requestedAmount = parseFloat(amount);

    // Validação básica de saldo
    if (requestedAmount > currentBalance) {
      return res.status(400).json({ 
        rejected: true, 
        reason: 'Saldo insuficiente na carteira.' 
      });
    }

    // Busca todas as regras de governança ATIVAS do banco
    const { data: activePolicies, error: policyErr } = await supabase
      .from('policy_rules')
      .select('*')
      .eq('is_active', true);

    if (policyErr) {
      return res.status(500).json({ error: 'Erro ao consultar regras de governança.' });
    }

    // Processamento dinâmico de cada regra ativa
    for (const policy of activePolicies) {
      // Regra 1: Porcentagem máxima do saldo por operação
      if (policy.rule_name === 'MAX_WALLET_USAGE_THRESHOLD') {
        const maxThreshold = policy.parameters.max_usage_percentage;
        if (requestedAmount > (currentBalance * maxThreshold)) {
          return res.status(403).json({
            rejected: true,
            code: 'POLICY_VIOLATION_THRESHOLD_EXCEEDED',
            reason: `A transação excede a trava de segurança de ${(maxThreshold * 100)}% do saldo disponível.`
          });
        }
      }

      // Regra 2: Valor máximo fixo por transação individual
      if (policy.rule_name === 'MAX_SINGLE_TRANSACTION_LIMIT') {
        const maxAmount = policy.parameters.max_amount;
        if (requestedAmount > maxAmount) {
          return res.status(403).json({
            rejected: true,
            code: 'POLICY_VIOLATION_MAX_AMOUNT_EXCEEDED',
            reason: `A transação excede o limite máximo permitido de R$ ${maxAmount.toFixed(2)} por operação.`
          });
        }
      }
    }

    // Transação aprovada por todas as políticas: atualiza o saldo
    const newBalance = currentBalance - requestedAmount;

    await supabase
      .from('wallets')
      .update({ balance: newBalance, updated_at: new Date() })
      .eq('id', wallet_id);

    // Registra entrada imutável no Ledger
    const { data: ledgerEntry } = await supabase
      .from('ledger_transactions')
      .insert([{
        wallet_id,
        amount: requestedAmount,
        previous_balance: currentBalance,
        new_balance: newBalance,
        operation_type,
        description
      }])
      .select();

    return res.json({ success: true, transaction: ledgerEntry[0] });

  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`[Synapse Backend] Servidor rodando na porta ${PORT}`);
});