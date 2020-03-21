import { Hex, randomHex } from 'web3-utils';

import * as circomlib from 'circomlib';
import { BabyJubjub } from './jubjub';
import { Field } from './field';
import * as chacha20 from 'chacha20';
import { getTokenId, getTokenAddress } from './tokens';
import { PublicData, Outflow } from './transaction';

const poseidonHash = circomlib.poseidon.createHash(6, 8, 57, 'poseidon');

export class UTXO {
  eth: Field;
  pubKey: BabyJubjub.Point;
  salt: Field;
  token: Field;
  amount: Field;
  nft: Field;
  publicData?: {
    isWithdrawal: boolean;
    to: Field;
    fee: Field;
  };

  constructor(eth: Field, salt: Field, token: Field, amount: Field, nft: Field, pubKey: BabyJubjub.Point, migrationTo?: Field) {
    this.eth = eth;
    this.pubKey = pubKey;
    this.salt = salt;
    this.token = token;
    this.amount = amount;
    this.nft = nft;
  }

  static newEtherNote(eth: Hex | Field, pubKey: BabyJubjub.Point, salt?: Field): UTXO {
    salt = salt ? salt : Field.from(randomHex(16));
    return new UTXO(Field.from(eth), salt, Field.from(0), Field.from(0), Field.from(0), pubKey);
  }

  static newERC20Note(eth: Hex | Field, addr: Hex | Field, amount: Hex | Field, pubKey: BabyJubjub.Point, salt?: Field): UTXO {
    salt = salt ? salt : Field.from(randomHex(16));
    return new UTXO(Field.from(eth), salt, Field.from(addr), Field.from(amount), Field.from(0), pubKey);
  }

  static newNFTNote(eth: Hex | Field, addr: Hex | Field, id: Hex | Field, pubKey: BabyJubjub.Point, salt?: Field): UTXO {
    salt = salt ? salt : Field.from(randomHex(16));
    return new UTXO(Field.from(eth), salt, Field.from(addr), Field.from(0), Field.from(id), pubKey);
  }

  withdrawTo(to: Field, fee: Field) {
    this.publicData = { isWithdrawal: true, to, fee };
  }

  migrateTo(to: Field, fee: Field) {
    this.publicData = { isWithdrawal: false, to, fee };
  }

  hash(): Field {
    let firstHash = Field.from(poseidonHash([this.eth.val, this.pubKey.x.val, this.pubKey.y, this.salt.val]));
    let resultHash = Field.from(poseidonHash([firstHash, this.token.val, this.amount.val, this.nft.val]));
    return resultHash;
  }

  nullifier(): Field {
    return Field.from(poseidonHash([this.hash(), this.salt.val]));
  }

  encrypt(): Buffer {
    let ephemeralSecretKey: Field = Field.from(randomHex(16));
    let sharedKey: Buffer = this.pubKey.mul(ephemeralSecretKey).encode();
    let tokenId = getTokenId(this.token);
    let value = this.eth ? this.eth : this.amount ? this.amount : this.nft;
    let secret = [this.salt.toBuffer(16), Field.from(tokenId).toBuffer(1), value.toBuffer(32)];
    let ciphertext = chacha20.encrypt(sharedKey, 0, Buffer.concat(secret));
    let encryptedMemo = Buffer.concat([BabyJubjub.Point.generate(ephemeralSecretKey).encode(), ciphertext]);
    // 32bytes ephemeral pub key + 16 bytes salt + 1 byte token id + 32 bytes value = 81 bytes
    return encryptedMemo;
  }

  toOutflow(): Outflow {
    let outflow = {
      note: this.hash(),
      outflowType: this.outflowType()
    };
    if (this.publicData) {
      outflow['data'] = {
        to: this.publicData.to,
        eth: this.eth,
        token: this.token,
        amount: this.amount,
        nft: this.nft,
        fee: this.publicData.fee
      };
    }
    return outflow;
  }

  toJSON(): string {
    return JSON.stringify({
      eth: this.eth,
      salt: this.salt,
      token: this.token,
      amount: this.amount,
      nft: this.nft.toHex(),
      pubKey: {
        x: this.pubKey.x,
        y: this.pubKey.y
      }
    });
  }

  outflowType(): Field {
    if (this.publicData) {
      if (this.publicData.isWithdrawal) {
        return Field.from(1); // Withdrawal
      } else {
        return Field.from(2); // Migration
      }
    } else {
      return Field.from(0); // UTXO
    }
  }

  static fromJSON(data: string): UTXO {
    let obj = JSON.parse(data);
    return new UTXO(obj.eth, obj.salt, obj.token, obj.amount, obj.nft, new BabyJubjub.Point(obj.pubKey.x, obj.pubKey.y));
  }

  static decrypt(utxoHash: Field, memo: Buffer, privKey: string): UTXO {
    let multiplier = BabyJubjub.Point.getMultiplier(privKey);
    let ephemeralPubKey = BabyJubjub.Point.decode(memo.subarray(0, 32));
    let sharedKey = ephemeralPubKey.mul(multiplier).encode();
    let data = memo.subarray(32, 81);
    let decrypted = chacha20.decrypt(sharedKey, 0, data); // prints "testing"

    let salt = Field.fromBuffer(decrypted.subarray(0, 16));
    let tokenAddress = getTokenAddress(decrypted.subarray(16, 17)[0]);
    let value = Field.fromBuffer(decrypted.subarray(17, 49));

    let myPubKey: BabyJubjub.Point = BabyJubjub.Point.fromPrivKey(privKey);
    if (tokenAddress.isZero()) {
      let etherNote = UTXO.newEtherNote(value, myPubKey, salt);
      if (utxoHash.equal(etherNote.hash())) {
        return etherNote;
      }
    } else {
      let erc20Note = UTXO.newERC20Note(Field.from(0), tokenAddress, value, myPubKey, salt);
      if (utxoHash.equal(erc20Note.hash())) {
        return erc20Note;
      }
      let nftNote = UTXO.newNFTNote(Field.from(0), tokenAddress, value, myPubKey, salt);
      if (utxoHash.equal(nftNote.hash())) {
        return nftNote;
      }
    }
    return null;
  }
}
